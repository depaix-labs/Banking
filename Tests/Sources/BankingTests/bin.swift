import Banking
import Bunq
import Foundation
import PayNL
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum TestFailure: Error {
    case fixture
}

private struct FixtureSigner: Bunq.Signing {
    let publicKeyPEM = "fixture-public-key"
    func sign(_ body: Data) throws -> String { "fixture-signature" }
    func verify(_ body: Data, signature: String, publicKey: String) throws {
        guard signature == "fixture-signature", publicKey == "fixture-server-key" else {
            throw TestFailure.fixture
        }
    }
}

private actor BunqFixture {
    private(set) var reads = 0

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw TestFailure.fixture }
        let payload: String
        switch (url.path, url.query ?? "") {
        case ("/v1/installation", _):
            payload = #"{"Response":[{"Token":{"token":"install"}},{"ServerPublicKey":{"server_public_key":"fixture-server-key"}}]}"#
        case ("/v1/device-server", _):
            payload = #"{"Response":[{"Id":{"id":1}}]}"#
        case ("/v1/session-server", _):
            payload = #"{"Response":[{"Token":{"token":"session"}},{"UserCompany":{"id":5}}]}"#
        case ("/v1/user/5/monetary-account", "count=100"):
            payload = #"{"Response":[{"MonetaryAccountBank":{"id":23}}],"Pagination":{"older_url":"/v1/user/5/monetary-account?older_id=22"}}"#
        case ("/v1/user/5/monetary-account", "count=100&older_id=22"):
            payload = #"{"Response":[{"MonetaryAccountBank":{"id":22}}],"Pagination":{"older_url":null}}"#
        case ("/v1/user/5/monetary-account/23/payment", "count=100"):
            payload = #"{"Response":[{"Payment":{"id":9,"monetary_account_id":23,"amount":{"value":"1.00","currency":"EUR"}}}],"Pagination":{"older_url":"/v1/user/5/monetary-account/23/payment?older_id=8"}}"#
        case ("/v1/user/5/monetary-account/23/payment", "count=100&older_id=8"):
            payload = #"{"Response":[{"Payment":{"id":8,"monetary_account_id":23,"amount":{"value":"2.00","currency":"EUR"}}}],"Pagination":{"older_url":null}}"#
        case ("/v1/user/5/monetary-account/22/payment", "count=100"):
            payload = #"{"Response":[],"Pagination":{"older_url":null}}"#
        default:
            throw TestFailure.fixture
        }
        if request.httpMethod == "GET" { reads += 1 }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["X-Bunq-Server-Signature": "fixture-signature"]
        ) else { throw TestFailure.fixture }
        return (Data(payload.utf8), response)
    }
}

private actor PayFixture {
    private(set) var reads = 0
    private let mismatchedDetailID: Bool

    init(mismatchedDetailID: Bool = false) {
        self.mismatchedDetailID = mismatchedDetailID
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw TestFailure.fixture }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
        let payload: String
        switch (url.path, page) {
        case ("/v2/clearings", "1"):
            payload = #"{"total":2,"count":1,"pages":2,"clearings":[{"id":"CLEARING-1"}]}"#
        case ("/v2/clearings", "2"):
            payload = #"{"total":2,"count":1,"pages":2,"clearings":[{"id":"CLEARING-2"}]}"#
        case ("/v2/clearings/CLEARING-1", _):
            payload = #"{"id":"CLEARING-1","status":"PAID"}"#
        case ("/v2/clearings/CLEARING-2", _):
            payload = #"{"id":"CLEARING-2","status":"PAID"}"#
        case ("/v2/clearings/CLEARING-1/lines", _):
            payload = #"{"total":1,"count":1,"pages":1,"clearingLines":[{"code":"LINE-1"}]}"#
        case ("/v2/clearings/CLEARING-2/lines", _):
            payload = #"{"total":0,"count":0,"pages":0,"clearingLines":[]}"#
        case ("/v2/clearings/settlements", _):
            payload = #"{"total":1,"count":1,"pages":1,"settlements":[{"code":"SET-1"}]}"#
        case ("/v2/transactions", _):
            payload = #"{"total":2,"count":2,"pages":1,"transactions":[{"id":"EX-1"},{"id":"EX-2"}]}"#
        case ("/v2/transactions/EX-1", _):
            payload = #"{"id":"EX-1","amount":{"value":123,"currency":"EUR"}}"#
        case ("/v2/transactions/EX-2", _):
            payload = mismatchedDetailID
                ? #"{"id":"EX-OTHER","orderId":"ORDER-OTHER","amount":{"value":456,"currency":"EUR"}}"#
                : #"{"id":"EX-2","amount":{"value":456,"currency":"EUR"}}"#
        default:
            throw TestFailure.fixture
        }
        reads += 1
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: [:]
        ) else { throw TestFailure.fixture }
        return (Data(payload.utf8), response)
    }
}

private actor ProgressFixtureSink: PayNLProgressSink {
    private(set) var events: [PayNLProgressEvent] = []

    func emit(_ event: PayNLProgressEvent) {
        events.append(event)
    }

    func transactionDetails() -> [(Int, Int?, Int)] {
        events.compactMap { event in
            guard case let .progressed(stage, completed, total, mismatches) = event,
                  stage == .transaction_details else { return nil }
            return (completed, total, mismatches)
        }
    }
}

private actor FirstRunGate {
    private var accepted = 0

    func permit() throws {
        guard accepted < 3 else { throw TestFailure.fixture }
        accepted += 1
    }
}

private func testResumeArchive() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-resume-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let coverage = "fixture GMS and Idefix endpoints"
    let firstArchive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture", coverage: coverage
    )
    let gate = FirstRunGate()
    let firstFixture = PayFixture()
    let firstCapture = ReadCapture()
    let firstTransport = PayNL.Transport { request in
        try await gate.permit()
        let (data, response) = try await firstFixture.send(request)
        await firstCapture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let key = try PayNL.Secret("fixture")
    let firstGMS = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: firstTransport
    )
    let firstIdefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: firstTransport
    )
    do {
        try await SourceIngestion.paynl(
            gms: firstGMS, idefix: firstIdefix,
            capture: firstCapture, archive: firstArchive
        )
        throw TestFailure.fixture
    } catch TestFailure.fixture {
        // An intentional transport interruption leaves committed pages intact.
    }

    let manifestURL = firstArchive.directory.appendingPathComponent("manifest.json")
    let partial = try JSONDecoder().decode(SourceManifest.self, from: Data(contentsOf: manifestURL))
    guard partial.status == "incomplete", partial.pages.count == 3,
          partial.streams.count == 1 else { throw TestFailure.fixture }
    do {
        _ = try SourceArchive.finalize(at: firstArchive.directory)
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // A partial acquisition cannot be finalized, even if all existing pages hash correctly.
    }
    let original = try partial.pages.map {
        try Data(contentsOf: firstArchive.directory.appendingPathComponent($0.file))
    }

    let resumed = try SourceArchive(
        resuming: firstArchive.directory, root: root, year: 2026,
        provider: "paynl", environment: "fixture", coverage: coverage
    )
    let cached = await resumed.archivedPageCount()
    guard cached == 3 else { throw TestFailure.fixture }

    let secondFixture = PayFixture()
    let secondCapture = ReadCapture()
    let secondTransport = PayNL.Transport { request in
        let data: Data
        let response: HTTPURLResponse
        if let replayed = try await resumed.replay(request) {
            (data, response) = replayed
        } else {
            (data, response) = try await secondFixture.send(request)
        }
        await secondCapture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let secondGMS = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: secondTransport
    )
    let secondIdefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: secondTransport
    )
    try await SourceIngestion.paynl(
        gms: secondGMS, idefix: secondIdefix,
        capture: secondCapture, archive: resumed
    )
    let complete = try SourceArchive.verify(at: firstArchive.directory)
    let liveReads = await secondFixture.reads
    guard complete.status == "complete", complete.pages.count == 10,
          complete.streams.count == 7, liveReads == 7 else { throw TestFailure.fixture }
    for (index, page) in partial.pages.enumerated() {
        let preserved = try Data(contentsOf: firstArchive.directory.appendingPathComponent(page.file))
        guard preserved == original[index] else { throw TestFailure.fixture }
    }
    do {
        _ = try SourceArchive(
            resuming: firstArchive.directory, root: root, year: 2026,
            provider: "paynl", environment: "fixture", coverage: coverage
        )
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // A completed archive is never writable through resume.
    }

    let corrupt = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture", coverage: coverage
    )
    guard let url = URL(string: "https://rest.pay.nl/v2/clearings?page=1"),
          let response = HTTPURLResponse(
              url: url, statusCode: 200, httpVersion: nil, headerFields: [:]
          ) else { throw TestFailure.fixture }
    let corruptionCapture = ReadCapture()
    await corruptionCapture.observe(
        request: URLRequest(url: url), response: response, body: Data("{\"ok\":true}".utf8)
    )
    let captured = try await corruptionCapture.take(expectedPath: "/v2/clearings")
    try await corrupt.append(
        stream: "paynl-clearings", scope: "all", page: 1,
        captured: captured, itemCount: 1
    )
    try Data("corrupted".utf8).write(
        to: corrupt.directory.appendingPathComponent("paynl-clearings/page-000001.json")
    )
    do {
        _ = try SourceArchive(
            resuming: corrupt.directory, root: root, year: 2026,
            provider: "paynl", environment: "fixture", coverage: coverage
        )
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Corrupted evidence fails before a single network request is possible.
    }
}

private func testArchive() async throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let bunqFixture = BunqFixture()
    let bunqCapture = ReadCapture()
    let bunqTransport = Bunq.Transport { request in
        let (data, response) = try await bunqFixture.send(request)
        await bunqCapture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let bunq = try await Bunq.Client.open(
        environment: .sandbox,
        apiKey: try Bunq.APIKey("fixture-key"),
        signing: FixtureSigner(),
        registration: .register(try Bunq.Device(description: "fixture")),
        transport: bunqTransport
    )
    let bunqArchive = try SourceArchive(
        root: temp, year: 2026, provider: "bunq", environment: "sandbox",
        coverage: "fixture monetary-account and payment endpoints"
    )
    try await SourceIngestion.bunq(client: bunq, capture: bunqCapture, archive: bunqArchive)
    let bunqManifest = try SourceArchive.verify(at: bunqArchive.directory)
    let bunqReads = await bunqFixture.reads
    guard bunqManifest.status == "complete", bunqManifest.pages.count == 5,
          bunqManifest.streams.count == 3, bunqReads == 5,
          bunqManifest.pages.allSatisfy({ $0.serverSignature == "fixture-signature" })
    else { throw TestFailure.fixture }

    // Offline Bunq catalog: account records and account-scoped payment records.
    let bunqManifestFile = bunqArchive.directory.appendingPathComponent("manifest.json")
    let bunqManifestBytes = try Data(contentsOf: bunqManifestFile)
    let bunqPageDigests = bunqManifest.pages.map(\.sha256)
    let bunqCatalog = try BunqSourceCatalog.build(
        sourceRun: bunqArchive.directory, accountScope: "fixture-bunq"
    )
    let repeated = try BunqSourceCatalog.build(
        sourceRun: bunqArchive.directory, accountScope: "fixture-bunq"
    )
    let bunqAccounts = bunqCatalog.observations.filter { $0.kind == .bunq_account }
    let bunqPayments = bunqCatalog.observations.filter { $0.kind == .bunq_payment }
    guard bunqCatalog.provider == "bunq", bunqCatalog.environment == "sandbox",
          bunqCatalog.schemaVersion == 1,
          bunqCatalog.coverage.acquisition == "complete",
          bunqCatalog.coverage.historicalCoverage == "unknown",
          bunqCatalog.coverage.streams.count == 3,
          bunqAccounts.count == 2, bunqPayments.count == 2,
          Set(bunqAccounts.map(\.externalID)) == Set(["22", "23"]),
          bunqAccounts.allSatisfy({ $0.parentExternalID == "5" }),
          Set(bunqPayments.map(\.externalID)) == Set(["8", "9"]),
          bunqPayments.allSatisfy({ $0.parentExternalID == "23" }),
          bunqCatalog.observations.allSatisfy({ $0.references.count == 1 &&
              $0.references[0].manifestSHA256 == bunqCatalog.manifestSHA256 &&
              $0.references[0].recordIndex >= 0 &&
              $0.detailIdentity == .not_applicable }),
          bunqCatalog.observations.map(\.key) == repeated.observations.map(\.key),
          try Data(contentsOf: bunqManifestFile) == bunqManifestBytes,
          try SourceArchive.verify(at: bunqArchive.directory).pages.map(\.sha256) == bunqPageDigests,
          await bunqFixture.reads == bunqReads
    else { throw TestFailure.fixture }

    // Identical provider records in another run retain the same logical keys.
    let copiedRun = temp.appendingPathComponent("copied-bunq-run", isDirectory: true)
    try FileManager.default.copyItem(at: bunqArchive.directory, to: copiedRun)
    let copiedCatalog = try BunqSourceCatalog.build(sourceRun: copiedRun, accountScope: "fixture-bunq")
    guard copiedCatalog.observations.map(\.key) == bunqCatalog.observations.map(\.key)
    else { throw TestFailure.fixture }
    let alternateScope = try BunqSourceCatalog.build(
        sourceRun: copiedRun, accountScope: "different-tenant"
    )
    guard Set(alternateScope.observations.map(\.key)).isDisjoint(
        with: Set(bunqCatalog.observations.map(\.key))
    ) else { throw TestFailure.fixture }

    let catalogOutput = temp.appendingPathComponent("bunq-derived-catalog", isDirectory: true)
    try SourceCatalogWriter.write(bunqCatalog, to: catalogOutput)
    guard FileManager.default.fileExists(
        atPath: catalogOutput.appendingPathComponent("observations.json").path
    ), FileManager.default.fileExists(
        atPath: catalogOutput.appendingPathComponent("coverage.json").path
    ) else { throw TestFailure.fixture }
    do {
        try SourceCatalogWriter.write(bunqCatalog, to: catalogOutput)
        throw TestFailure.fixture
    } catch SourceFailure.unsafeOutput {
        // Derived catalog output cannot overwrite an existing catalog.
    }
    do {
        try SourceCatalogWriter.write(
            bunqCatalog, to: bunqArchive.directory.appendingPathComponent("derived")
        )
        throw TestFailure.fixture
    } catch SourceFailure.unsafeOutput {
        // Derived output cannot be written into immutable raw evidence.
    }
    do {
        _ = try BunqSourceCatalog.build(sourceRun: copiedRun, accountScope: "bad/scope")
        throw TestFailure.fixture
    } catch SourceFailure.invalidScope {
        // Scope values must not contain path separators.
    }
    guard let copiedPage = bunqManifest.pages.first else { throw TestFailure.fixture }
    try Data(#"{"Response":[]}"#.utf8).write(
        to: copiedRun.appendingPathComponent(copiedPage.file)
    )
    do {
        _ = try BunqSourceCatalog.build(sourceRun: copiedRun, accountScope: "fixture-bunq")
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Tampered evidence cannot be indexed.
    }

    let payFixture = PayFixture()
    let payCapture = ReadCapture()
    let payTransport = PayNL.Transport { request in
        let (data, response) = try await payFixture.send(request)
        await payCapture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let secret = try PayNL.Secret("fixture")
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: secret, api_token: secret), transport: payTransport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: secret, password: secret), transport: payTransport
    )
    let payArchive = try SourceArchive(
        root: temp, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "fixture GMS and Idefix endpoints"
    )
    let payProgress = ProgressFixtureSink()
    try await SourceIngestion.paynl(
        gms: gms, idefix: idefix, capture: payCapture, archive: payArchive,
        sink: payProgress
    )
    let payDetailProgress = await payProgress.transactionDetails()
    guard payDetailProgress.contains(where: { $0.0 == 0 && $0.1 == 2 }),
          payDetailProgress.last.map({ $0.0 == 2 && $0.1 == 2 && $0.2 == 0 }) == true
    else { throw TestFailure.fixture }
    let payManifest = try SourceArchive.verify(at: payArchive.directory)
    let payReads = await payFixture.reads
    guard payManifest.status == "complete", payManifest.pages.count == 10,
          payManifest.streams.count == 7, payReads == 10,
          payManifest.identityReconciliation == SourceIdentityReconciliation(
              status: .matched, discrepancyCount: 0
          ),
          payManifest.pages.allSatisfy({ $0.serverSignature == nil })
    else { throw TestFailure.fixture }

    guard let first = payManifest.pages.first else { throw TestFailure.fixture }
    try Data(#"{"tampered":true}"#.utf8).write(
        to: payArchive.directory.appendingPathComponent(first.file)
    )
    do {
        _ = try SourceArchive.verify(at: payArchive.directory)
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Tampering must be detectable offline.
    }

    let incomplete = try SourceArchive(
        root: temp, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "incomplete fixture"
    )
    let inspected = try SourceArchive.inspect(at: incomplete.directory)
    guard inspected.status == "incomplete", inspected.pages.isEmpty,
          inspected.streams.isEmpty else { throw TestFailure.fixture }
    do {
        _ = try SourceArchive.verify(at: incomplete.directory)
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // An interrupted run is never accepted as a complete archive.
    }
    do {
        _ = try SourceArchive.finalize(at: incomplete.directory)
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // No streams means there is no completed acquisition to finalize.
    }
}

private func testPayNLCaptureIdentityFailures() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-identity-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    guard let firstURL = URL(string: "https://rest.pay.nl/v2/transactions/EX-1"),
          let response = HTTPURLResponse(
              url: firstURL, statusCode: 200, httpVersion: nil, headerFields: [:]
          ) else { throw TestFailure.fixture }
    let capture = ReadCapture()
    await capture.observe(
        request: URLRequest(url: firstURL), response: response, body: Data("{}".utf8)
    )
    do {
        _ = try await capture.take(expectedPath: "/v2/transactions/EX-2")
        throw TestFailure.fixture
    } catch SourceFailure.capturePathMismatch {
        // A path mismatch must not be mistaken for an ID mismatch.
    }
    _ = try await capture.take(expectedPath: "/v2/transactions/EX-1")
    do {
        _ = try await capture.take(expectedPath: "/v2/transactions/EX-1")
        throw TestFailure.fixture
    } catch SourceFailure.captureQueueMismatch(actual: 0) {
        // A missing capture has its own bounded diagnostic.
    }

    let key = try PayNL.Secret("fixture")
    let fixture = PayFixture(mismatchedDetailID: true)
    let readCapture = ReadCapture()
    let transport = PayNL.Transport { request in
        let (data, response) = try await fixture.send(request)
        await readCapture.observe(request: request, response: response, body: data)
        return (data, response)
    }
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: transport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: transport
    )
    let archive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "mismatched transaction detail test"
    )
    let mismatchProgress = ProgressFixtureSink()
    try await SourceIngestion.paynl(
        gms: gms, idefix: idefix, capture: readCapture, archive: archive,
        sink: mismatchProgress
    )
    let reported = await mismatchProgress.transactionDetails()
    guard reported.last.map({ $0.0 == 2 && $0.1 == 2 && $0.2 == 1 }) == true
    else { throw TestFailure.fixture }
    let manifest = try SourceArchive.verify(at: archive.directory)
    guard manifest.status == "complete", manifest.pages.count == 10,
          manifest.identityReconciliation == SourceIdentityReconciliation(
              status: .unresolved, discrepancyCount: 1
          ),
          manifest.pages.last?.stream == "paynl-transaction-details",
          manifest.pages.last?.page == 2,
          manifest.pages.last?.detailMismatch?.expectedID == "EX-2",
          manifest.pages.last?.detailMismatch?.observedID == "EX-OTHER",
          manifest.pages.last?.detailMismatch?.observedIDInBrowse == false
    else { throw TestFailure.fixture }
}

private actor PayOrderIDFixture {
    private let base = PayFixture()
    private let wrongOrderDetail: Bool
    private(set) var badEXReads = 0

    init(wrongOrderDetail: Bool = false) {
        self.wrongOrderDetail = wrongOrderDetail
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw TestFailure.fixture }
        let payload: String
        switch url.path {
        case "/v2/transactions":
            payload = #"{"total":2,"count":2,"pages":1,"transactions":[{"id":"EX-1","orderId":"ORDER-1"},{"id":"EX-2","orderId":"ORDER-2"}]}"#
        case "/v2/transactions/EX-1", "/v2/transactions/ORDER-1":
            payload = #"{"id":"EX-1","orderId":"ORDER-1"}"#
        case "/v2/transactions/ORDER-2":
            payload = wrongOrderDetail
                ? #"{"id":"EX-OTHER","orderId":"ORDER-2"}"#
                : #"{"id":"EX-2","orderId":"ORDER-2"}"#
        case "/v2/transactions/EX-2":
            badEXReads += 1
            payload = #"{"id":"EX-OTHER","orderId":"ORDER-OTHER"}"#
        default:
            return try await base.send(request)
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: [:]
        ) else { throw TestFailure.fixture }
        return (Data(payload.utf8), response)
    }
}

private func testPAYOrderIDLookupAndResume() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-orderid-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try PayNL.Secret("fixture")

    let fixture = PayOrderIDFixture()
    let capture = ReadCapture()
    let archive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "order ID lookup fixture"
    )
    let transport = PayNL.Transport { request in
        let (body, response) = try await fixture.send(request)
        await capture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: transport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: transport
    )
    try await SourceIngestion.paynl(gms: gms, idefix: idefix, capture: capture, archive: archive)
    let complete = try SourceArchive.verify(at: archive.directory)
    let freshPaths = complete.pages.filter { $0.stream == "paynl-transaction-details" }
        .sorted { $0.page < $1.page }.map(\.path)
    let badEXReads = await fixture.badEXReads
    guard freshPaths == ["/v2/transactions/ORDER-1", "/v2/transactions/ORDER-2"],
          badEXReads == 0 else { throw TestFailure.fixture }

    // Simulate an old, incomplete run with its first detail already committed
    // using the original EX-code locator. Resume must replay that same request.
    let existing = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "preexisting EX detail fixture"
    )
    guard let firstURL = URL(string: "https://rest.pay.nl/v2/transactions/EX-1"),
          let firstResponse = HTTPURLResponse(
              url: firstURL, statusCode: 200, httpVersion: nil, headerFields: [:]
          ) else { throw TestFailure.fixture }
    let firstCapture = ReadCapture()
    await firstCapture.observe(
        request: URLRequest(url: firstURL), response: firstResponse,
        body: Data(#"{"id":"EX-1","orderId":"ORDER-1"}"#.utf8)
    )
    let saved = try await firstCapture.take(expectedPath: "/v2/transactions/EX-1")
    try await existing.append(
        stream: "paynl-transaction-details", scope: "all", page: 1,
        captured: saved, itemCount: 1
    )
    let resumed = try SourceArchive(
        resuming: existing.directory, root: root, year: 2026,
        provider: "paynl", environment: "fixture",
        coverage: "preexisting EX detail fixture"
    )
    let resumeFixture = PayOrderIDFixture()
    let resumeCapture = ReadCapture()
    let resumeTransport = PayNL.Transport { request in
        let response: (Data, HTTPURLResponse)
        if let cached = try await resumed.replay(request) {
            response = cached
        } else {
            response = try await resumeFixture.send(request)
        }
        await resumeCapture.observe(
            request: request, response: response.1, body: response.0
        )
        return response
    }
    let resumeGMS = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: resumeTransport
    )
    let resumeIdefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: resumeTransport
    )
    try await SourceIngestion.paynl(
        gms: resumeGMS, idefix: resumeIdefix,
        capture: resumeCapture, archive: resumed
    )
    let resumedManifest = try SourceArchive.verify(at: resumed.directory)
    let resumedPaths = resumedManifest.pages.filter { $0.stream == "paynl-transaction-details" }
        .sorted { $0.page < $1.page }.map(\.path)
    let resumedEXReads = await resumeFixture.badEXReads
    guard resumedPaths == ["/v2/transactions/EX-1", "/v2/transactions/ORDER-2"],
          resumedEXReads == 0 else { throw TestFailure.fixture }

    // The order ID matches but the returned EX code is distinct. Acquire and
    // retain the response, then keep identity reconciliation explicitly unresolved.
    let mismatchFixture = PayOrderIDFixture(wrongOrderDetail: true)
    let mismatchCapture = ReadCapture()
    let mismatchArchive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "order ID mismatch fixture"
    )
    let mismatchTransport = PayNL.Transport { request in
        let (body, response) = try await mismatchFixture.send(request)
        await mismatchCapture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let mismatchGMS = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: mismatchTransport
    )
    let mismatchIdefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: mismatchTransport
    )
    try await SourceIngestion.paynl(
        gms: mismatchGMS, idefix: mismatchIdefix,
        capture: mismatchCapture, archive: mismatchArchive
    )
    let completed = try SourceArchive.verify(at: mismatchArchive.directory)
    let anomalies = completed.pages.compactMap(\.detailMismatch)
    guard completed.status == "complete", completed.pages.count == 10,
          completed.identityReconciliation == SourceIdentityReconciliation(
              status: .unresolved, discrepancyCount: 1
          ),
          anomalies.count == 1,
          anomalies[0].expectedID == "EX-2",
          anomalies[0].observedID == "EX-OTHER",
          anomalies[0].expectedOrderID == "ORDER-2",
          anomalies[0].observedOrderID == "ORDER-2",
          anomalies[0].observedIDInBrowse == false
    else { throw TestFailure.fixture }

    // Simulate the legacy failure: all raw pages and stream records have been
    // committed but the manifest was left incomplete by identity reconciliation.
    // Only fixture metadata is changed; raw response bytes remain untouched.
    let manifestURL = mismatchArchive.directory.appendingPathComponent("manifest.json")
    let originalHashes = completed.pages.map(\.sha256)
    var legacy = completed
    legacy.status = "incomplete"
    legacy.finishedAt = nil
    legacy.identityReconciliation = nil
    try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)
    let pending = try SourceArchive.inspect(at: mismatchArchive.directory)
    guard pending.status == "incomplete", pending.identityReconciliation == nil else {
        throw TestFailure.fixture
    }

    // Legacy reopening preserves exact identities. Replay must use zero network
    // requests even though 1 recorded detail is disputed.
    let reopened = try SourceArchive(
        resuming: mismatchArchive.directory, root: root, year: 2026,
        provider: "paynl", environment: "fixture", coverage: "order ID mismatch fixture"
    )
    let cachedDetail = await reopened.archivedPage(stream: "paynl-transaction-details", page: 2)
    guard cachedDetail?.detailMismatch == anomalies[0] else { throw TestFailure.fixture }
    let replayCapture = ReadCapture()
    let replayTransport = PayNL.Transport { request in
        guard let cached = try await reopened.replay(request) else { throw TestFailure.fixture }
        await replayCapture.observe(request: request, response: cached.1, body: cached.0)
        return cached
    }
    let replayGMS = PayNL.GMS.Client(
        credentials: .apiToken(at_code: key, api_token: key), transport: replayTransport
    )
    let replayIdefix = PayNL.Idefix.Client(
        credentials: .init(username: key, password: key), transport: replayTransport
    )
    try await SourceIngestion.paynl(
        gms: replayGMS, idefix: replayIdefix,
        capture: replayCapture, archive: reopened
    )
    let replayed = try SourceArchive.verify(at: mismatchArchive.directory)
    guard replayed.pages.map(\.sha256) == originalHashes,
          replayed.pages.compactMap(\.detailMismatch) == anomalies,
          replayed.identityReconciliation == completed.identityReconciliation
    else { throw TestFailure.fixture }

    // Offline finalization of an equivalent legacy run must not require network
    // access, and must preserve original SHA-256 and dispute metadata.
    legacy.status = "incomplete"
    legacy.finishedAt = nil
    legacy.identityReconciliation = nil
    try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)
    let finalized = try SourceArchive.finalize(at: mismatchArchive.directory)
    guard finalized.status == "complete",
          finalized.identityReconciliation == completed.identityReconciliation,
          finalized.pages.map(\.sha256) == originalHashes,
          finalized.pages.compactMap(\.detailMismatch) == anomalies
    else { throw TestFailure.fixture }
    // Repeated offline finalization is a verified no-op, not a false failure.
    // Both the manifest's bytes and the original raw responses must stay intact.
    let finalizedManifestBytes = try Data(contentsOf: manifestURL)
    let finalizedAgain = try SourceArchive.finalize(at: mismatchArchive.directory)
    let finalizedManifestBytesAgain = try Data(contentsOf: manifestURL)
    guard finalizedAgain.status == "complete",
          finalizedAgain.finishedAt == finalized.finishedAt,
          finalizedAgain.identityReconciliation == finalized.identityReconciliation,
          finalizedAgain.pages.map(\.sha256) == originalHashes,
          finalizedManifestBytesAgain == finalizedManifestBytes
    else { throw TestFailure.fixture }
    do {
        _ = try SourceArchive(
            resuming: mismatchArchive.directory, root: root, year: 2026,
            provider: "paynl", environment: "fixture", coverage: "order ID mismatch fixture"
        )
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Completed evidence can no longer be mutated through resume.
    }

}

private func testPAYIdentityProbe() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-paynl-probe-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "probe fixture with one order-ID identity mismatch"
    )
    let capture = ReadCapture()
    let fixture = PayOrderIDFixture(wrongOrderDetail: true)
    let transport = PayNL.Transport { request in
        let (body, response) = try await fixture.send(request)
        await capture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let secret = try PayNL.Secret("fixture")
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: secret, api_token: secret), transport: transport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: secret, password: secret), transport: transport
    )
    try await SourceIngestion.paynl(gms: gms, idefix: idefix, capture: capture, archive: archive)
    let before = try SourceArchive.verify(at: archive.directory)
    guard before.identityReconciliation == SourceIdentityReconciliation(
        status: .unresolved, discrepancyCount: 1
    ) else { throw TestFailure.fixture }
    let manifestURL = archive.directory.appendingPathComponent("manifest.json")
    let manifestBefore = try Data(contentsOf: manifestURL)
    let bodyHashes = before.pages.map(\.sha256)

    // An EX-code lookup returns the expected attempt. No network is used.
    let probeCapture = ReadCapture()
    let probeTransport = PayNL.Transport { request in
        guard let url = request.url, url.path == "/v2/transactions/EX-2",
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil, headerFields: [:]
              ) else { throw TestFailure.fixture }
        let body = Data(#"{"id":"EX-2","orderId":"ORDER-2"}"#.utf8)
        await probeCapture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let probeClient = PayNL.Idefix.Client(
        credentials: .init(username: secret, password: secret), transport: probeTransport
    )
    let destination = root.appendingPathComponent("ex-probe-success")
    let success = try await PayNLIdentityProbe.run(
        sourceRun: archive.directory, outputDirectory: destination,
        client: probeClient, capture: probeCapture
    )
    guard success.status == "complete", success.selectedCount == 1,
          success.totalArchivedMismatches == 1, success.eligibleOrderLookups == 1,
          success.comparisons.count == 1,
          success.comparisons[0].exIDMatchesListing,
          success.comparisons[0].orderIDMatchesListing,
          !success.comparisons[0].exIDMatchesOrderLookup,
          success.comparisons[0].amountMatchesListing == nil,
          success.comparisons[0].statusMatchesListing == nil
    else { throw TestFailure.fixture }
    let report = try JSONDecoder().decode(
        PayNLIdentityProbe.Report.self,
        from: Data(contentsOf: destination.appendingPathComponent("report.json"))
    )
    guard report.comparisons.count == 1,
          report.comparisons[0].rawSHA256 == SourceArchive.sha256(
              try Data(contentsOf: destination.appendingPathComponent(report.comparisons[0].rawFile))
          ) else { throw TestFailure.fixture }

    // An EX-code lookup may still resolve incorrectly. Preserve that result;
    // do not falsely treat its matching order lookup as reconciliation.
    let unresolvedCapture = ReadCapture()
    let unresolvedFixture = PayOrderIDFixture(wrongOrderDetail: true)
    let unresolvedTransport = PayNL.Transport { request in
        guard request.url?.path == "/v2/transactions/EX-2" else {
            throw TestFailure.fixture
        }
        let (body, response) = try await unresolvedFixture.send(request)
        await unresolvedCapture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let unresolvedClient = PayNL.Idefix.Client(
        credentials: .init(username: secret, password: secret), transport: unresolvedTransport
    )
    let unresolved = try await PayNLIdentityProbe.run(
        sourceRun: archive.directory,
        outputDirectory: root.appendingPathComponent("ex-probe-discrepancy"),
        client: unresolvedClient, capture: unresolvedCapture, sampleCount: 1
    )
    guard unresolved.comparisons.count == 1,
          !unresolved.comparisons[0].exIDMatchesListing,
          !unresolved.comparisons[0].orderIDMatchesListing
    else { throw TestFailure.fixture }

    let after = try SourceArchive.verify(at: archive.directory)
    guard try Data(contentsOf: manifestURL) == manifestBefore,
          after.pages.map(\.sha256) == bodyHashes,
          after.identityReconciliation == before.identityReconciliation
    else { throw TestFailure.fixture }
}

/// Full offline identity/financial classification on a verified fixture.
private actor PAYAuditFixture {
    private let base = PayFixture()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw TestFailure.fixture }
        let payload: String
        switch url.path {
        case "/v2/transactions":
            payload = #"{"total":6,"count":6,"pages":1,"transactions":[{"id":"EX-1","orderId":"ORDER-1","amount":{"value":100,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"}},{"id":"EX-2","orderId":"ORDER-2","amount":{"value":200,"currency":"EUR"},"status":{"code":-80,"action":"CANCEL","phase":"EXPIRED"},"createdAt":"2026-02-08T08:53:43+01:00"},{"id":"EX-3","orderId":"ORDER-3","amount":{"value":300,"currency":"EUR"},"status":{"code":-90,"action":"CANCEL","phase":"CANCELLED"},"createdAt":"2026-06-03T18:05:43+02:00"},{"id":"EX-4","orderId":"ORDER-4","amount":{"value":400,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"}},{"id":"EX-5","orderId":"ORDER-5","amount":{"value":500,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"}},{"id":"EX-6","orderId":"ORDER-6","amount":{"value":600,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"},"createdAt":"2026-02-08T08:53:43+01:00"}]}"#
        case "/v2/transactions/ORDER-1":
            payload = #"{"id":"EX-1","orderId":"ORDER-1","amount":{"value":100,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"}}"#
        case "/v2/transactions/ORDER-2":
            payload = #"{"id":"ORDER-2","orderId":"ORDER-2","amount":{"value":200,"currency":"EUR"},"status":{"code":-80,"action":"CANCEL","phase":"EXPIRED"},"createdAt":"2026-02-08T07:53:43+00:00"}"#
        case "/v2/transactions/ORDER-3":
            payload = #"{"id":"ORDER-3","orderId":"ORDER-3","amount":{"value":300,"currency":"EUR"},"status":{"code":-90,"action":"CANCEL","phase":"CANCELLED"},"createdAt":"2026-06-03T16:05:42+00:00"}"#
        case "/v2/transactions/ORDER-4":
            payload = #"{"id":"EX-ALTERNATE-4","orderId":"ORDER-4","amount":{"value":400,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"}}"#
        case "/v2/transactions/ORDER-5":
            payload = #"{"id":"EX-ALTERNATE-5","orderId":"ORDER-5","amount":{"value":501,"currency":"EUR"},"status":{"code":200,"action":"PAID","phase":"SUCCESS"}}"#
        case "/v2/transactions/ORDER-6":
            payload = #"{"id":"EX-ALTERNATE-6","orderId":"ORDER-6","amount":{"value":600,"currency":"EUR"},"status":{"code":100,"action":"PAID","phase":"SUCCESS"},"createdAt":"2026-02-08T07:53:53+00:00"}"#
        default:
            return try await base.send(request)
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: [:]
        ) else { throw TestFailure.fixture }
        return (Data(payload.utf8), response)
    }
}

private func testPAYIdentityAudit() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banking-paynl-audit-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = ReadCapture()
    let fixture = PAYAuditFixture()
    let transport = PayNL.Transport { request in
        let (body, response) = try await fixture.send(request)
        await capture.observe(request: request, response: response, body: body)
        return (body, response)
    }
    let secret = try PayNL.Secret("fixture")
    let gms = PayNL.GMS.Client(
        credentials: .apiToken(at_code: secret, api_token: secret), transport: transport
    )
    let idefix = PayNL.Idefix.Client(
        credentials: .init(username: secret, password: secret), transport: transport
    )
    let archive = try SourceArchive(
        root: root, year: 2026, provider: "paynl", environment: "fixture",
        coverage: "offline identity audit regression fixture"
    )
    try await SourceIngestion.paynl(
        gms: gms, idefix: idefix, capture: capture, archive: archive
    )
    let before = try SourceArchive.verify(at: archive.directory)
    guard before.identityReconciliation == SourceIdentityReconciliation(
        status: .unresolved, discrepancyCount: 5
    ) else { throw TestFailure.fixture }
    let manifestURL = archive.directory.appendingPathComponent("manifest.json")
    let manifestBefore = try Data(contentsOf: manifestURL)
    let bodyDigests = before.pages.map(\.sha256)
    // Build a deterministic offline catalog from the same unresolved source run.
    let catalog = try PayNLSourceCatalog.build(
        sourceRun: archive.directory, accountScope: "fixture-merchant"
    )
    let transactions = catalog.observations.filter { $0.kind == .paynl_transaction }
    let clearings = catalog.observations.filter { $0.kind == .paynl_clearing }
    let lines = catalog.observations.filter { $0.kind == .paynl_clearing_line }
    let settlements = catalog.observations.filter { $0.kind == .paynl_settlement }
    let observedOrderIDs = transactions.filter {
        $0.detailIdentity == .unresolved && $0.detailObservedID == $0.orderID
    }
    guard catalog.schemaVersion == 1,
          catalog.coverage.acquisition == "complete",
          catalog.coverage.historicalCoverage == "unknown",
          transactions.count == 6, clearings.count == 2,
          lines.count == 1, settlements.count == 1,
          catalog.observations.count == 10,
          transactions.allSatisfy({ $0.references.count == 2 }),
          clearings.allSatisfy({ $0.references.count == 2 }),
          observedOrderIDs.count == 2,
          transactions.filter({ $0.detailIdentity == .unresolved }).count == 5,
          Set(catalog.observations.map(\.key)).count == catalog.observations.count,
          transactions.contains(where: { $0.externalID == "EX-2" && $0.detailObservedID == "ORDER-2" })
    else { throw TestFailure.fixture }
    let again = try PayNLSourceCatalog.build(
        sourceRun: archive.directory, accountScope: "fixture-merchant"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard try encoder.encode(catalog) == encoder.encode(again) else {
        throw TestFailure.fixture
    }
    let firstCatalogPath = root.appendingPathComponent("catalog-first")
    let secondCatalogPath = root.appendingPathComponent("catalog-second")
    try PayNLSourceCatalog.write(catalog, to: firstCatalogPath)
    try PayNLSourceCatalog.write(again, to: secondCatalogPath)
    guard try Data(contentsOf: firstCatalogPath.appendingPathComponent("observations.json")) ==
              Data(contentsOf: secondCatalogPath.appendingPathComponent("observations.json"))
    else { throw TestFailure.fixture }
    do {
        try PayNLSourceCatalog.write(catalog, to: firstCatalogPath)
        throw TestFailure.fixture
    } catch SourceFailure.unsafeOutput {
        // No silent overwrite of a previous derived report.
    }
    let destination = root.appendingPathComponent("audit-report")
    let audit = try PayNLIdentityAudit.run(
        sourceRun: archive.directory, outputDirectory: destination
    )
    let types = audit.classificationCounts
    guard audit.browseCount == 6, audit.detailCount == 6,
          audit.archivedFlaggedCount == 5,
          types[PayNLIdentityAudit.Classification.no_identity_discrepancy.rawValue] == 1,
          types[PayNLIdentityAudit.Classification.order_id_returned_as_transaction_id.rawValue] == 2,
          types[PayNLIdentityAudit.Classification.identifier_only_financial_fields_match.rawValue] == 1,
          types[PayNLIdentityAudit.Classification.financial_difference.rawValue] == 1,
          types[PayNLIdentityAudit.Classification.other_field_difference.rawValue] == 1,
          audit.records.map(\.detailPage) == [1, 2, 3, 4, 5, 6],
          audit.records[1].metadataAgreesWithBodies,
          audit.records[1].createdAtRelationship == .same_instant,
          audit.records[1].createdAtDeltaSeconds == 0,
          audit.records[1].fields.first(where: { $0.name == "created_at" })?.result == .matched,
          audit.records[2].createdAtRelationship == .detail_one_second_earlier,
          audit.records[2].createdAtDeltaSeconds == -1,
          audit.records[2].fields.first(where: { $0.name == "created_at" })?.result == .different,
          audit.records[3].classification == .identifier_only_financial_fields_match,
          audit.records[4].classification == .financial_difference,
          audit.records[5].classification == .other_field_difference,
          audit.records[4].fields.first(where: { $0.name == "amount_minor" })?.result == .different,
          audit.records[4].fields.first(where: { $0.name == "status" })?.result == .different,
          audit.timestampRelationshipCountsOnFlaggedRecords["same_instant"] == 1,
          audit.timestampRelationshipCountsOnFlaggedRecords["detail_one_second_earlier"] == 1,
          audit.timestampRelationshipCountsOnFlaggedRecords["unavailable"] == 2,
          audit.timestampRelationshipCountsOnFlaggedRecords["different"] == 1
    else { throw TestFailure.fixture }
    let stored = try JSONDecoder().decode(
        PayNLIdentityAudit.Report.self,
        from: Data(contentsOf: destination.appendingPathComponent("report.json"))
    )
    guard stored.schemaVersion == 2, stored.records.count == 6,
          stored.sourceManifestSHA256 == SourceArchive.sha256(manifestBefore),
          stored.fieldCountsOnFlaggedRecords["amount_minor"]?.different == 1,
          stored.fieldCountsOnFlaggedRecords["amount_minor"]?.matched == 4
    else { throw TestFailure.fixture }
    do {
        _ = try PayNLIdentityAudit.run(
            sourceRun: archive.directory, outputDirectory: destination
        )
        throw TestFailure.fixture
    } catch SourceFailure.unsafeOutput {
        // Audits never overwrite earlier reports.
    }
    let after = try SourceArchive.verify(at: archive.directory)
    guard try Data(contentsOf: manifestURL) == manifestBefore,
          after.pages.map(\.sha256) == bodyDigests,
          after.identityReconciliation == before.identityReconciliation
    else { throw TestFailure.fixture }

    // Tampering is rejected before a new audit report can be created.
    guard let detailPage = before.pages.first(where: { $0.stream == "paynl-transaction-details" })
    else { throw TestFailure.fixture }
    try Data(#"{"id":"tampered"}"#.utf8).write(
        to: archive.directory.appendingPathComponent(detailPage.file)
    )
    do {
        _ = try PayNLIdentityAudit.run(
            sourceRun: archive.directory,
            outputDirectory: root.appendingPathComponent("should-not-exist")
        )
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Hash-corrupt input cannot be audited or silently normalized.
    }
    do {
        _ = try PayNLSourceCatalog.build(
            sourceRun: archive.directory, accountScope: "fixture-merchant"
        )
        throw TestFailure.fixture
    } catch SourceFailure.invalidArchive {
        // Tampered archive cannot produce a catalog.
    }
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path)
    else { throw TestFailure.fixture }
}

@main
private enum TestExecutable {
    static func main() async throws {
        try await testArchive()
        try await testResumeArchive()
        try await testPayNLReadGovernor()
        try await testPayNLCaptureIdentityFailures()
        try await testPAYOrderIDLookupAndResume()
        try await testPAYIdentityProbe()
        try await testPAYIdentityAudit()
        print("Banking acquisition, pagination, archive and tamper fixtures: PASS")
    }
}
