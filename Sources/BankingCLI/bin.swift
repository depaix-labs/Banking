import Arguments
import Banking
import Bunq
import Foundation
import Milieu
import PayNL
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum CommandFailure: Error {
    case arguments
    case missingContext
    case unavailableKeyPath
}

private struct FetchOptions {
    let provider: String
    let sourcesRoot: URL
    let year: Int
    let environment: String?
    let registerDevice: Bool
    let paynlIntervalMilliseconds: Int
    let paynlMaximumRetries: Int
    let resumeRun: URL?

    init(_ invocation: ParsedInvocation) throws {
        let provider = try invocation.require("provider", as: String.self)
        let root = try invocation.require("sources-root", as: String.self)
        let year = try invocation.require("year", as: Int.self)
        let environment = try invocation.value("environment", as: String.self)
        let registerDevice = try invocation.flag("register-device")
        let paynlIntervalMilliseconds = try invocation.value("paynl-interval-ms", as: Int.self) ?? 2_000
        let paynlMaximumRetries = try invocation.value("paynl-429-retries", as: Int.self) ?? 5
        let resumePath = try invocation.value("resume-run", as: String.self)

        guard ["bunq", "paynl"].contains(provider),
              root.hasPrefix("/"),
              (2000...2100).contains(year),
              (0...60_000).contains(paynlIntervalMilliseconds),
              (0...8).contains(paynlMaximumRetries),
              resumePath == nil || (provider == "paynl" && resumePath?.hasPrefix("/") == true)
        else { throw CommandFailure.arguments }

        if provider == "bunq" {
            guard let environment, ["sandbox", "production"].contains(environment) else {
                throw CommandFailure.arguments
            }
        } else if environment != nil || registerDevice {
            throw CommandFailure.arguments
        }

        self.provider = provider
        sourcesRoot = URL(fileURLWithPath: root, isDirectory: true)
        self.year = year
        self.environment = environment
        self.registerDevice = registerDevice
        self.paynlIntervalMilliseconds = paynlIntervalMilliseconds
        self.paynlMaximumRetries = paynlMaximumRetries
        resumeRun = resumePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

private func runBunq(_ options: FetchOptions) async throws {
    guard let name = options.environment else { throw CommandFailure.arguments }
    let environment: Bunq.Environment = name == "sandbox" ? .sandbox : .production
    let apiKeyName = name == "sandbox" ? "BUNQ_SANDBOX_API_KEY" : "BUNQ_PRODUCTION_API_KEY"
    let apiKey = try Bunq.APIKey(EnvironmentExtractor.value(apiKeyName))
    let replacer = EnvironmentReplacer(replacements: [
        .home,
        .variable(
            key: "myworkdir/programming",
            replacement: .value("main/programming/bundles")
        ),
    ])
    let publicPath = try EnvironmentExtractor.value("BUNQ_PUBLIC_KEY_PATH", replacer: replacer)
    let privatePath = try EnvironmentExtractor.value("BUNQ_PRIVATE_KEY_PATH", replacer: replacer)
    guard FileManager.default.isReadableFile(atPath: publicPath),
          FileManager.default.isReadableFile(atPath: privatePath)
    else { throw CommandFailure.unavailableKeyPath }
    let signing = try Bunq.SigningIdentity(
        publicKeyURL: URL(fileURLWithPath: publicPath),
        privateKeyURL: URL(fileURLWithPath: privatePath)
    )
    let contextVariable = name == "sandbox" ? "BUNQ_SANDBOX_CONTEXT_PATH" : "BUNQ_PRODUCTION_CONTEXT_PATH"
    let overridden = EnvironmentExtractor.optional(contextVariable, replacer: replacer)
        ?? (name == "sandbox" ? EnvironmentExtractor.optional("BUNQ_CONTEXT_PATH", replacer: replacer) : nil)
    let contextPath = overridden ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/bunq/\(name)-context.json").path
    let store = Bunq.FileContextStore(url: URL(fileURLWithPath: contextPath))
    let registration: Bunq.Registration
    if let saved = try await store.load() {
        let restored = try saved.restore(
            environment: environment, apiKey: apiKey, signing: signing
        )
        registration = .reuse(restored.installation)
    } else {
        guard options.registerDevice else { throw CommandFailure.missingContext }
        registration = .register(try Bunq.Device(description: "Banking source acquisition"))
    }
    let capture = ReadCapture()
    let transport = Bunq.Transport { request in
        let (data, response) = try await Bunq.Transport.live.send(request)
        await capture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let client = try await Bunq.Client.open(
        environment: environment, apiKey: apiKey, signing: signing,
        registration: registration, transport: transport, contextStore: store
    )
    let archive = try SourceArchive(
        root: options.sourcesRoot, year: options.year, provider: "bunq",
        environment: name,
        coverage: "All visible monetary-account and payment endpoint pages, unfiltered by year; not a complete Bunq statement or all movement types"
    )
    print("Bunq evidence run: \(archive.directory.path)")
    try await SourceIngestion.bunq(client: client, capture: capture, archive: archive)
    _ = try SourceArchive.verify(at: archive.directory)
    print("PASS Bunq raw source acquisition: completed and SHA-256 verified")
}

/// Tracks only endpoint families and page numbers; request credentials and
/// provider record identifiers never enter diagnostic output.
private actor PayNLFetchTrace: PayNLProgressSink {
    private var previousProgressStage: PayNLProgressEvent.Stage?
    private var endpoint = "none"
    private var page = "-"
    private var source = "pending"
    private var status: Int?
    private var archivedReads = 0
    private var liveReads = 0

    func begin(_ request: URLRequest) {
        guard let url = request.url else { return }
        let path = url.path
        switch path {
        case "/v2/clearings":
            endpoint = "clearings"
        case "/v2/clearings/settlements":
            endpoint = "settlements"
        case "/v2/transactions":
            endpoint = "transactions"
        case _ where path.hasPrefix("/v2/clearings/") && path.hasSuffix("/lines"):
            endpoint = "clearing-lines"
        case _ where path.hasPrefix("/v2/clearings/"):
            endpoint = "clearing-detail"
        case _ where path.hasPrefix("/v2/transactions/"):
            endpoint = "transaction-detail"
        default:
            endpoint = "other"
        }
        page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "page" })?.value ?? "-"
        source = "pending"
        status = nil
    }

    func received(cached: Bool, status: Int) {
        if cached {
            archivedReads += 1
        } else {
            liveReads += 1
        }
        source = cached ? "archive" : "live"
        self.status = status
    }

    func liveRequestWillStart() {
        log("PAY. live GET \(liveReads + 1): \(endpoint), page=\(page)")
    }

    func emit(_ event: PayNLProgressEvent) {
        switch event {
        case let .progressed(stage, completed, total, identityMismatches):
            let changedStage = previousProgressStage != stage
            previousProgressStage = stage
            guard changedStage || completed == total || completed % 5 == 0 else { return }
            let fraction = total.map { "\(completed)/\($0)" } ?? String(completed)
            let issues = identityMismatches > 0 ? ", identity-mismatches=\(identityMismatches)" : ""
            log("PAY. \(stage.rawValue): \(fraction)\(issues)")
        case let .rate_limited(retry, maximumRetries, wait, stopping):
            if stopping {
                log("PAY. HTTP 429: stopping after retry \(retry)/\(maximumRetries); wait=\(wait.map { String(describing: $0) } ?? "-")")
            } else {
                log("PAY. HTTP 429: retry \(retry)/\(maximumRetries) after \(wait ?? .zero)")
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    func summary() -> String {
        "endpoint=\(endpoint), page=\(page), source=\(source), " +
            "http=\(status.map(String.init) ?? "-"), " +
            "cached-reads=\(archivedReads), live-reads=\(liveReads)"
    }
}

private func runPayNL(_ options: FetchOptions) async throws {
    let atCode = try PayNL.Secret(EnvironmentExtractor.value("PAYNL_API_AT"))
    let apiToken = try PayNL.Secret(EnvironmentExtractor.value("PAYNL_API_TOKEN"))
    let coverage = "All visible GMS clearings, clearing lines, settlements and Idefix transactions plus details, unfiltered by year"
    let archive: SourceArchive
    if let resumeRun = options.resumeRun {
        archive = try SourceArchive(
            resuming: resumeRun, root: options.sourcesRoot, year: options.year,
            provider: "paynl", environment: "merchant-api", coverage: coverage
        )
        let count = await archive.archivedPageCount()
        print("PAY. resuming verified evidence: \(count) cached responses")
    } else {
        archive = try SourceArchive(
            root: options.sourcesRoot, year: options.year, provider: "paynl",
            environment: "merchant-api", coverage: coverage
        )
    }
    let capture = ReadCapture()
    let policy = try PayNLReadPolicy(
        minimumInterval: .milliseconds(options.paynlIntervalMilliseconds),
        maximumRetries: options.paynlMaximumRetries
    )
    let trace = PayNLFetchTrace()
    let governor = PayNLReadGovernor(policy: policy, sink: trace)
    let transport = PayNL.Transport { request in
        await trace.begin(request)
        let data: Data
        let response: HTTPURLResponse
        let cached: Bool
        if let archived = try await archive.replay(request) {
            (data, response) = archived
            cached = true
        } else {
            await trace.liveRequestWillStart()
            (data, response) = try await governor.send(request)
            cached = false
        }
        await trace.received(cached: cached, status: response.statusCode)
        await capture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: atCode, api_token: apiToken),
        transport: transport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: atCode, password: apiToken),
        transport: transport
    )
    print("PAY. evidence run: \(archive.directory.path)")
    do {
        try await SourceIngestion.paynl(
            gms: gms, idefix: idefix, capture: capture, archive: archive, sink: trace
        )
        let final = try SourceArchive.verify(at: archive.directory)
        print("PASS PAY. raw source acquisition: complete and SHA-256 verified")
        print(reconciliationSummary(final))
    } catch {
        let last = await trace.summary()
        let count = await archive.archivedPageCount()
        let category = error is SourceFailure
            ? String(describing: error)
            : String(describing: type(of: error))
        FileHandle.standardError.write(Data(
            "PAY. acquisition stopped: \(category); \(last); archived-pages=\(count)\n".utf8
        ))
        throw error
    }
}

/// No provider identifiers or transaction contents appear in status output.
private func reconciliationSummary(_ manifest: SourceManifest) -> String {
    if let assessment = manifest.identityReconciliation {
        return "PAY. identity reconciliation: \(assessment.status.rawValue), discrepancies=\(assessment.discrepancyCount)"
    }
    let archived = manifest.pages.filter { $0.detailMismatch != nil }.count
    return "PAY. identity reconciliation: pending, archived-discrepancies=\(archived)"
}

private enum FetchCommand: RunnableArgumentCommand {
    static let name = "fetch"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Acquire complete visible provider endpoint histories into a raw evidence archive."),
            opt("provider", as: String.self, arity: .required, help: "bunq or paynl"),
            opt("sources-root", as: String.self, arity: .required, help: "Absolute archive root"),
            opt("year", as: Int.self, arity: .required, help: "Output partition year"),
            opt("environment", as: String.self, help: "Bunq sandbox or production"),
            flag("register-device", help: "Explicitly permit initial Bunq device registration"),
            opt("paynl-interval-ms", as: Int.self, help: "PAY. delay between reads (default 2000 ms)"),
            opt("paynl-429-retries", as: Int.self, help: "PAY. maximum retries after HTTP 429 (default 5)"),
            opt("resume-run", as: String.self, help: "Resume a verified incomplete PAY. evidence run"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let options = try FetchOptions(invocation)
        switch options.provider {
        case "bunq":
            try await runBunq(options)
        case "paynl":
            try await runPayNL(options)
        default:
            throw CommandFailure.arguments
        }
    }
}

private enum InspectRunCommand: RunnableArgumentCommand {
    static let name = "inspect-run"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Inspect a completed or incomplete evidence run offline; verify every archived page."),
            arg("run-directory", as: String.self, help: "Absolute path to an existing run"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let path = try invocation.require("run-directory", as: String.self)
        guard path.hasPrefix("/") else { throw CommandFailure.arguments }
        let manifest = try SourceArchive.inspect(at: URL(fileURLWithPath: path, isDirectory: true))
        print(
            "PASS evidence integrity: \(manifest.provider), status=\(manifest.status), " +
            "pages=\(manifest.pages.count), finished-streams=\(manifest.streams.count)"
        )
        if let last = manifest.pages.last {
            print("Last committed: stream=\(last.stream), page=\(last.page)")
        }
        let mismatches = manifest.pages.compactMap(\.detailMismatch)
        if manifest.provider == "paynl" {
            print(reconciliationSummary(manifest))
            if !mismatches.isEmpty {
                let inBrowse = mismatches.filter(\.observedIDInBrowse).count
                print("Unexpected returned EX codes also present in browse: \(inBrowse)")
            }
        }
        let finished = Set(manifest.streams.map(\.name))
        let unfinished = Dictionary(grouping: manifest.pages, by: \.stream)
            .filter { !finished.contains($0.key) }
            .sorted { $0.key < $1.key }
        for (stream, pages) in unfinished {
            print("Unfinished: stream=\(stream), pages=\(pages.count)")
        }
    }
}

/// Finishes only fully acquired, byte-verified legacy PAY. runs; no credentials
/// or network clients are constructed by this command.
private enum FinalizeRunCommand: RunnableArgumentCommand {
    static let name = "finalize-run"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Finalize fully acquired, byte-verified PAY. evidence without contacting PAY."),
            arg("run-directory", as: String.self, help: "Absolute path to an existing PAY. run"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let path = try invocation.require("run-directory", as: String.self)
        guard path.hasPrefix("/") else { throw CommandFailure.arguments }
        let manifest = try SourceArchive.finalize(at: URL(fileURLWithPath: path, isDirectory: true))
        print("PASS PAY. offline acquisition finalization: complete, pages=\(manifest.pages.count), streams=\(manifest.streams.count)")
        print(reconciliationSummary(manifest))
    }
}

private enum VerifyRunCommand: RunnableArgumentCommand {
    static let name = "verify-run"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Verify the integrity of an existing source-acquisition run offline."),
            arg("run-directory", as: String.self, help: "Absolute path to a completed run"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let path = try invocation.require("run-directory", as: String.self)
        guard path.hasPrefix("/") else { throw CommandFailure.arguments }
        let manifest = try SourceArchive.verify(
            at: URL(fileURLWithPath: path, isDirectory: true)
        )
        print(
            "PASS archive integrity: \(manifest.provider), acquisition=complete, " +
            "\(manifest.pages.count) pages, \(manifest.streams.count) streams"
        )
        if manifest.provider == "paynl" { print(reconciliationSummary(manifest)) }
    }
}

/// Collect a bounded diagnostic sample in a new evidence directory; never
/// change the completed PAY. acquisition or silently accept mismatched EX IDs.
private enum ProbePayNLIdentitiesCommand: RunnableArgumentCommand {
    static let name = "probe-paynl-identities"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Compare archived PAY. order-ID details with five fresh EX-ID lookups."),
            arg("run-directory", as: String.self, help: "Absolute path to a completed PAY. run"),
            opt("sample-count", as: Int.self, help: "Distinct discrepant records to inspect (default 5, max 10)"),
            opt("paynl-interval-ms", as: Int.self, help: "Minimum delay between live reads (default 2000 ms)"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let path = try invocation.require("run-directory", as: String.self)
        let sample = try invocation.value("sample-count", as: Int.self) ?? 5
        let interval = try invocation.value("paynl-interval-ms", as: Int.self) ?? 2_000
        guard path.hasPrefix("/"), (1...10).contains(sample), (0...60_000).contains(interval)
        else { throw CommandFailure.arguments }

        let source = URL(fileURLWithPath: path, isDirectory: true)
        // Reject invalid archives before opening credentials or creating output.
        let verified = try SourceArchive.verify(at: source)
        guard verified.provider == "paynl",
              verified.identityReconciliation?.status == .unresolved
        else { throw SourceFailure.invalidArchive }
        let outputRoot = source.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("identity-probes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identifier = Date().ISO8601Format().lowercased()
            .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.lowercased()
        let destination = outputRoot.appendingPathComponent(identifier, isDirectory: true)

        let atCode = try PayNL.Secret(EnvironmentExtractor.value("PAYNL_API_AT"))
        let token = try PayNL.Secret(EnvironmentExtractor.value("PAYNL_API_TOKEN"))
        let capture = ReadCapture()
        let policy = try PayNLReadPolicy(minimumInterval: .milliseconds(interval))
        let governor = PayNLReadGovernor(policy: policy)
        let transport = PayNL.Transport { request in
            let (data, response) = try await governor.send(request)
            await capture.observe(request: request, response: response, body: data)
            return (data, response)
        }
        let client = PayNL.Idefix.Client(
            credentials: .init(username: atCode, password: token), transport: transport
        )
        print("PAY. identity probe evidence: \(destination.path)")
        let report = try await PayNLIdentityProbe.run(
            sourceRun: source, outputDirectory: destination,
            client: client, capture: capture, sampleCount: sample
        )
        let matchedEX = report.comparisons.filter(\.exIDMatchesListing).count
        let matchedOrder = report.comparisons.filter(\.orderIDMatchesListing).count
        print("PASS PAY. EX-ID probe: \(report.comparisons.count)/\(report.selectedCount) requests captured")
        print("Original EX ID matched: \(matchedEX)/\(report.selectedCount)")
        print("Original order ID matched: \(matchedOrder)/\(report.selectedCount)")
        print("Amount/currency/status comparisons and hashed raw responses: report.json")
        print("PAY. original archive remains verified and unchanged; reconciliation remains unresolved")
    }
}

/// Compare all verified PAY. browse rows with their archived detail bodies.
/// The audit is offline, credential-free, and does not change source evidence.
private enum AuditPayNLIdentitiesCommand: RunnableArgumentCommand {
    static let name = "audit-paynl-identities"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Audit all archived PAY. transaction identities and financial fields offline."),
            arg("run-directory", as: String.self, help: "Absolute path to a verified PAY. evidence run"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let path = try invocation.require("run-directory", as: String.self)
        guard path.hasPrefix("/") else { throw CommandFailure.arguments }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        let verified = try SourceArchive.verify(at: source)
        guard verified.provider == "paynl" else { throw SourceFailure.invalidScope }
        let root = source.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("identity-audits", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let identifier = Date().ISO8601Format().lowercased()
            .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent(identifier, isDirectory: true)
        let report = try PayNLIdentityAudit.run(
            sourceRun: source, outputDirectory: destination
        )
        func count(_ name: PayNLIdentityAudit.Classification) -> Int {
            report.classificationCounts[name.rawValue, default: 0]
        }
        print("PASS PAY. offline identity audit: \(report.detailCount)/\(report.browseCount) details compared")
        print("Flagged identity discrepancies: \(report.archivedFlaggedCount)")
        print("Observed order ID in detail id, EX identity unresolved: \(count(.order_id_returned_as_transaction_id))")
        let times = report.timestampRelationshipCountsOnFlaggedRecords
        print("Creation instants matched (timezone normalized): \(times["same_instant", default: 0])")
        print("Detail created one second earlier: \(times["detail_one_second_earlier", default: 0])")
        print("Identifier-only, critical financial fields matched: \(count(.identifier_only_financial_fields_match))")
        print("Identifier-only, financial fields unavailable: \(count(.identifier_only_financial_fields_unavailable))")
        print("Financial field differences: \(count(.financial_difference))")
        print("Other field differences: \(count(.other_field_difference))")
        print("Order differences: \(count(.order_difference))")
        print("Archive metadata inconsistencies: \(count(.inconsistent_archive_metadata))")
        print("Full per-record and per-field report: \(destination.appendingPathComponent("report.json").path)")
        print("No PAY. requests made; source evidence and identity reconciliation unchanged")
    }
}

/// The catalog is derived, versioned output. It never acquires or rewrites raw evidence.
private enum CatalogCommand: ArgumentCommand {
    static let name = "catalog"
    static var children: [ArgumentCommandType] { [BuildCatalogCommand.self] }
}

private enum BuildCatalogCommand: RunnableArgumentCommand {
    static let name = "build"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Build an offline Bunq or PAY. catalog from a complete verified archive."),
            arg("run-directory", as: String.self, help: "Absolute path to a completed source run"),
            opt("account-scope", as: String.self, help: "Persistent local tenant/account scope (required)"),
            opt("output-directory", as: String.self, help: "New absolute directory for derived catalogs (required)"),
        ]
    }

    static func run(_ invocation: ParsedInvocation) async throws {
        let run = try invocation.require("run-directory", as: String.self)
        let scope = try invocation.require("account-scope", as: String.self)
        let output = try invocation.require("output-directory", as: String.self)
        guard run.hasPrefix("/"), output.hasPrefix("/") else { throw CommandFailure.arguments }
        let source = URL(fileURLWithPath: run, isDirectory: true)
        let manifest = try SourceArchive.verify(at: source)
        let catalog: SourceCatalog
        switch manifest.provider {
        case "paynl":
            catalog = try PayNLSourceCatalog.build(sourceRun: source, accountScope: scope)
        case "bunq":
            catalog = try BunqSourceCatalog.build(sourceRun: source, accountScope: scope)
        default:
            throw SourceFailure.invalidScope
        }
        try SourceCatalogWriter.write(
            catalog, to: URL(fileURLWithPath: output, isDirectory: true)
        )
        let byKind = Dictionary(grouping: catalog.observations, by: \.kind)
        print("PASS \(catalog.provider) catalog: \(catalog.observations.count) unique observations")
        let kinds: [SourceObservation.Kind]
        switch catalog.provider {
        case "bunq":
            kinds = [.bunq_account, .bunq_payment]
        case "paynl":
            kinds = [.paynl_transaction, .paynl_clearing, .paynl_clearing_line, .paynl_settlement]
        default:
            throw SourceFailure.invalidScope
        }
        for kind in kinds {
            print("\(kind.rawValue): \(byKind[kind]?.count ?? 0)")
        }
        if catalog.provider == "paynl" {
            let unresolved = catalog.observations.filter {
                $0.kind == .paynl_transaction && $0.detailIdentity == .unresolved
            }.count
            print("Unresolved transaction detail identities: \(unresolved)")
        }
        print("Historical completeness: \(catalog.coverage.historicalCoverage) (captured endpoints only)")
        print("Derived catalog: \(output)")
        print("Original archive unchanged; no provider requests made")
    }
}

@main
private enum BankingCommand: ArgumentCommand {
    static let name = "banking"

    static var children: [ArgumentCommandType] {
        [
            FetchCommand.self, InspectRunCommand.self, FinalizeRunCommand.self,
            VerifyRunCommand.self, ProbePayNLIdentitiesCommand.self,
            AuditPayNLIdentitiesCommand.self, CatalogCommand.self,
        ]
    }

    static func main() async {
        await ArgumentProgram.main(command: Self.self, errorHandler: { error in
            // No raw provider error payloads or authentication credentials are logged.
            let category: String
            switch error {
            case is ArgumentParseError, CommandFailure.arguments:
                category = "invalid command arguments; see banking --help"
            case CommandFailure.missingContext:
                category = "no stored Bunq installation; use --register-device to authorize first registration"
            case CommandFailure.unavailableKeyPath:
                category = "Bunq signing key paths cannot be read"
            case let failure as SourceFailure:
                category = "source invariant \(failure); evidence run remains incomplete"
            case let Bunq.Failure.http(status, _):
                category = "Bunq provider rejected the request with HTTP \(status)"
            case let PayNL.Failure.http(status):
                category = "PAY. provider rejected the request with HTTP \(status)"
            default:
                category = "authentication, transport or decoding failed (\(type(of: error)))"
            }
            FileHandle.standardError.write(Data("FAIL banking: \(category)\n".utf8))
            return 1
        })
    }
}
