import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SourceFailure: Error, Sendable {
    case invalidCapture
    case incompletePagination
    case duplicateRecord
    case invalidArchive
    case unsafeOutput
    case invalidScope
    case captureQueueMismatch(actual: Int)
    case capturePathMismatch
    case transactionDetailIdentityMismatch(orderIDMatchesRequest: Bool)
    case transactionDetailOrderIDMismatch
    case unresolvedDetailIdentities(count: Int)
}

public struct CapturedRead: Sendable {
    public let body: Data
    public let path: String
    public let query: String?
    public let serverSignature: String?
}

/// Capture transport bytes only; the caller consumes them after the SDK's normal
/// response validation (including Bunq response-signature verification) succeeds.
public actor ReadCapture {
    private var pending: [CapturedRead] = []

    public init() {}

    public func observe(request: URLRequest, response: HTTPURLResponse, body: Data) {
        guard request.httpMethod == "GET",
              (200..<300).contains(response.statusCode),
              let url = request.url, url.scheme == "https" else { return }
        pending.append(CapturedRead(
            body: body,
            path: url.path,
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
            serverSignature: response.value(forHTTPHeaderField: "X-Bunq-Server-Signature")
        ))
    }

    public func take(expectedPath: String) throws -> CapturedRead {
        guard pending.count == 1 else {
            throw SourceFailure.captureQueueMismatch(actual: pending.count)
        }
        guard pending[0].path == expectedPath else {
            throw SourceFailure.capturePathMismatch
        }
        return pending.removeFirst()
    }
}

/// A successful provider detail response whose identifiers do not reconcile with
/// its corresponding browse record. Raw bytes remain intact and independently hashed.
public struct SourceDetailMismatch: Codable, Sendable, Equatable {
    public let expectedID: String
    public let observedID: String
    public let expectedOrderID: String?
    public let observedOrderID: String?
    public let observedIDInBrowse: Bool

    public init(
        expectedID: String, observedID: String,
        expectedOrderID: String?, observedOrderID: String?,
        observedIDInBrowse: Bool
    ) {
        self.expectedID = expectedID
        self.observedID = observedID
        self.expectedOrderID = expectedOrderID
        self.observedOrderID = observedOrderID
        self.observedIDInBrowse = observedIDInBrowse
    }
}

public struct SourcePageEvidence: Codable, Sendable {
    public let stream: String
    public let scope: String
    public let page: Int
    public let path: String
    public let query: String?
    public let file: String
    public let bytes: Int
    public let sha256: String
    public let itemCount: Int
    public let serverSignature: String?
    public let detailMismatch: SourceDetailMismatch?
}

public struct SourceStreamEvidence: Codable, Sendable {
    public let name: String
    public let scope: String
    public let pages: Int
    public let itemCount: Int
}

/// Describes only the PAY. browse/detail identifier comparison, not accounting
/// reconciliation, settlement matching or entitlement to import disputed details.
public struct SourceIdentityReconciliation: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case matched
        case unresolved
        case not_applicable
    }

    public let status: Status
    public let discrepancyCount: Int

    public init(status: Status, discrepancyCount: Int) {
        self.status = status
        self.discrepancyCount = discrepancyCount
    }
}

public struct SourceManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let provider: String
    public let environment: String
    public let partitionYear: Int
    public let coverage: String
    public let startedAt: String
    public var finishedAt: String?
    public var status: String
    public var pages: [SourcePageEvidence]
    public var streams: [SourceStreamEvidence]
    /// Nil on pre-existing and unfinished manifests; populated only on finalization.
    /// Optional preserves decoding of archived schemaVersion 1 manifests.
    public var identityReconciliation: SourceIdentityReconciliation?
}

/// A run is uniquely named, never overwrites a prior run and begins as incomplete.
/// The year is an output partition, NOT a provider-side date filter.
public actor SourceArchive {
    public nonisolated let directory: URL
    private var manifest: SourceManifest
    private var indexedReads: [String: SourcePageEvidence] = [:]

    public init(root: URL, year: Int, provider: String, environment: String, coverage: String) throws {
        guard (2000...2100).contains(year),
              ["bunq", "paynl"].contains(provider),
              !environment.isEmpty, !coverage.isEmpty else { throw SourceFailure.invalidScope }
        let runs = root.appendingPathComponent(String(year), isDirectory: true)
            .appendingPathComponent("\(provider)-\(year)", isDirectory: true)
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runs, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let runID = Date().ISO8601Format().lowercased()
            .replacingOccurrences(of: ":", with: "-")
            + "-" + UUID().uuidString.lowercased()
        let runDirectory = runs.appendingPathComponent(runID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: runDirectory.path) else {
            throw SourceFailure.unsafeOutput
        }
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: runDirectory.path
        )
        directory = runDirectory
        manifest = SourceManifest(
            schemaVersion: 1, provider: provider, environment: environment,
            partitionYear: year, coverage: coverage, startedAt: Date().ISO8601Format(),
            finishedAt: nil, status: "incomplete", pages: [], streams: [],
            identityReconciliation: nil
        )
        try Self.writeManifest(manifest, in: runDirectory)
    }

    /// Reopen only an incomplete run after validating every archived byte.
    /// The original run directory and manifest remain authoritative.
    public init(
        resuming runDirectory: URL,
        root: URL,
        year: Int,
        provider: String,
        environment: String,
        coverage: String
    ) throws {
        let expectedParent = root.appendingPathComponent(String(year), isDirectory: true)
            .appendingPathComponent("\(provider)-\(year)", isDirectory: true)
            .appendingPathComponent("api/runs", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let actualDirectory = runDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard actualDirectory.deletingLastPathComponent() == expectedParent else {
            throw SourceFailure.invalidScope
        }

        guard let data = try? Data(contentsOf: actualDirectory.appendingPathComponent("manifest.json")),
              let restored = try? JSONDecoder().decode(SourceManifest.self, from: data)
        else { throw SourceFailure.invalidArchive }
        guard restored.status == "incomplete", restored.finishedAt == nil,
              restored.provider == provider, restored.environment == environment,
              restored.partitionYear == year, restored.coverage == coverage,
              try Self.verify(manifest: restored, in: actualDirectory, requireComplete: false)
        else { throw SourceFailure.invalidArchive }

        directory = actualDirectory
        manifest = restored
        indexedReads = Dictionary(uniqueKeysWithValues: restored.pages.map {
            (Self.readKey(path: $0.path, query: $0.query), $0)
        })
    }

    /// Return archived successful GET bytes without making a new provider request.
    /// The original archive bytes are re-validated and fed back through SDK decoding.
    public func replay(_ request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        guard request.httpMethod == "GET", let url = request.url, url.scheme == "https" else {
            return nil
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        let key = Self.readKey(path: url.path, query: query)
        guard let archived = indexedReads[key] else { return nil }
        let path = directory.appendingPathComponent(archived.file)
        let data = try Data(contentsOf: path)
        guard data.count == archived.bytes, Self.sha256(data) == archived.sha256 else {
            throw SourceFailure.invalidArchive
        }
        var headers: [String: String] = [:]
        if let signature = archived.serverSignature {
            headers["X-Bunq-Server-Signature"] = signature
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ) else { throw SourceFailure.invalidArchive }
        return (data, response)
    }

    public func archivedPageCount() -> Int { manifest.pages.count }

    /// Preserve the original request locator when replaying an archived detail.
    /// Existing PAY. detail pages may have been requested by EX code or order ID.
    public func archivedPage(stream: String, page: Int) -> SourcePageEvidence? {
        manifest.pages.first { $0.stream == stream && $0.page == page }
    }

    private static func readKey(path: String, query: String?) -> String {
        path + "?" + (query ?? "")
    }

    public func append(
        stream: String,
        scope: String,
        page: Int,
        captured: CapturedRead,
        itemCount: Int,
        detailMismatch: SourceDetailMismatch? = nil
    ) throws {
        guard Self.isKebabCase(stream), !scope.isEmpty,
              page > 0, itemCount >= 0, !captured.body.isEmpty,
              captured.path.hasPrefix("/"), !captured.path.contains("//"),
              manifest.status == "incomplete",
              detailMismatch == nil || (stream == "paynl-transaction-details" && itemCount == 1)
        else { throw SourceFailure.invalidArchive }
        let relative = "\(stream)/page-\(String(format: "%06d", page)).json"
        let key = Self.readKey(path: captured.path, query: captured.query)
        let digest = Self.sha256(captured.body)
        if let existing = manifest.pages.first(where: { $0.stream == stream && $0.page == page }) {
            guard existing.scope == scope, existing.file == relative,
                  existing.path == captured.path, existing.query == captured.query,
                  existing.bytes == captured.body.count, existing.sha256 == digest,
                  existing.itemCount == itemCount,
                  existing.serverSignature == captured.serverSignature,
                  existing.detailMismatch == detailMismatch
            else { throw SourceFailure.invalidArchive }
            return
        }
        guard indexedReads[key] == nil else { throw SourceFailure.invalidArchive }
        let target = directory.appendingPathComponent(relative)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw SourceFailure.unsafeOutput
        }
        try captured.body.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let evidence = SourcePageEvidence(
            stream: stream, scope: scope, page: page,
            path: captured.path, query: captured.query,
            file: relative, bytes: captured.body.count,
            sha256: digest, itemCount: itemCount,
            serverSignature: captured.serverSignature,
            detailMismatch: detailMismatch
        )
        manifest.pages.append(evidence)
        indexedReads[key] = evidence
        try Self.writeManifest(manifest, in: directory)
    }

    public func finishStream(name: String, scope: String, itemCount: Int) throws {
        guard Self.isKebabCase(name), !scope.isEmpty, itemCount >= 0,
              manifest.status == "incomplete" else { throw SourceFailure.invalidArchive }
        let pages = manifest.pages.filter { $0.stream == name }
            .sorted { $0.page < $1.page }
        guard !pages.isEmpty, pages.allSatisfy({ $0.scope == scope }),
              pages.enumerated().allSatisfy({ $0.element.page == $0.offset + 1 }),
              pages.reduce(0, { $0 + $1.itemCount }) == itemCount
        else { throw SourceFailure.incompletePagination }
        if let existing = manifest.streams.first(where: { $0.name == name }) {
            guard existing.scope == scope, existing.pages == pages.count,
                  existing.itemCount == itemCount else { throw SourceFailure.invalidArchive }
            return
        }
        manifest.streams.append(SourceStreamEvidence(
            name: name, scope: scope, pages: pages.count, itemCount: itemCount
        ))
        try Self.writeManifest(manifest, in: directory)
    }

    /// Marks *acquisition* complete after structural and SHA-256 verification.
    /// Identity mismatches remain unresolved evidence; they do not mean an HTTP
    /// response is missing. Consumers must gate use of disputed details separately.
    public func complete() throws {
        guard manifest.status == "incomplete", manifest.finishedAt == nil,
              manifest.identityReconciliation == nil, !manifest.streams.isEmpty,
              manifest.pages.count == manifest.streams.reduce(0, { $0 + $1.pages }),
              try Self.verify(manifest: manifest, in: directory, requireComplete: true)
        else { throw SourceFailure.invalidArchive }
        manifest.identityReconciliation = Self.identityAssessment(for: manifest)
        manifest.status = "complete"
        manifest.finishedAt = Date().ISO8601Format()
        try Self.writeManifest(manifest, in: directory)
    }

    /// Offline closure for fully acquired PAY. evidence, including legacy runs
    /// blocked by identity reconciliation. Already-complete runs are verified
    /// and returned unchanged, without rewriting the manifest or response bytes.
    /// Incomplete runs still require full coverage and SHA-256 integrity.
    public static func finalize(at directory: URL) throws -> SourceManifest {
        let existing = try inspect(at: directory)
        guard existing.provider == "paynl" else { throw SourceFailure.invalidArchive }
        if existing.status == "complete" {
            return try verify(at: directory)
        }

        var restored = existing
        guard restored.status == "incomplete",
              restored.finishedAt == nil, restored.identityReconciliation == nil,
              !restored.streams.isEmpty,
              restored.pages.count == restored.streams.reduce(0, { $0 + $1.pages }),
              try verify(manifest: restored, in: directory, requireComplete: true)
        else { throw SourceFailure.invalidArchive }
        restored.identityReconciliation = identityAssessment(for: restored)
        restored.status = "complete"
        restored.finishedAt = Date().ISO8601Format()
        try writeManifest(restored, in: directory)
        return try verify(at: directory)
    }

    private static func identityAssessment(for manifest: SourceManifest) -> SourceIdentityReconciliation {
        guard manifest.provider == "paynl" else {
            return SourceIdentityReconciliation(status: .not_applicable, discrepancyCount: 0)
        }
        let count = manifest.pages.filter { $0.detailMismatch != nil }.count
        return SourceIdentityReconciliation(
            status: count == 0 ? .matched : .unresolved,
            discrepancyCount: count
        )
    }

    /// Reconciliation does not establish acquisition completeness. This checks the
    /// endpoint families and the counts of all named detail/line streams collected
    /// by SourceIngestion.paynl, in addition to the generic per-byte checks.
    private static func hasCompletePAYCoverage(_ manifest: SourceManifest) -> Bool {
        let byName = Dictionary(uniqueKeysWithValues: manifest.streams.map { ($0.name, $0) })
        guard let clearings = byName["paynl-clearings"],
              let settlements = byName["paynl-settlements"],
              let transactions = byName["paynl-transactions"],
              clearings.pages > 0, settlements.pages > 0, transactions.pages > 0
        else { return false }

        let expectedBase: Set<String> = ["paynl-clearings", "paynl-settlements", "paynl-transactions"]
        let clearingDetail = byName["paynl-clearing-details"]
        let transactionDetail = byName["paynl-transaction-details"]
        if clearings.itemCount > 0 {
            guard let clearingDetail,
                  clearingDetail.pages == clearings.itemCount,
                  clearingDetail.itemCount == clearings.itemCount
            else { return false }
        } else if clearingDetail != nil {
            return false
        }
        if transactions.itemCount > 0 {
            guard let transactionDetail,
                  transactionDetail.pages == transactions.itemCount,
                  transactionDetail.itemCount == transactions.itemCount
            else { return false }
        } else if transactionDetail != nil {
            return false
        }

        let lines = manifest.streams.filter { $0.name.hasPrefix("paynl-clearing-lines-") }
        guard lines.count == clearings.itemCount,
              lines.allSatisfy({ $0.pages > 0 && !$0.scope.isEmpty })
        else { return false }
        var expectedNames = expectedBase
        if clearings.itemCount > 0 { expectedNames.insert("paynl-clearing-details") }
        if transactions.itemCount > 0 { expectedNames.insert("paynl-transaction-details") }
        expectedNames.formUnion(lines.map(\.name))
        return expectedNames == Set(manifest.streams.map(\.name))
    }

    /// Verify the archived bytes and structural invariants of either an incomplete
    /// or completed run without making any provider requests or changing evidence.
    public static func inspect(at directory: URL) throws -> SourceManifest {
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(SourceManifest.self, from: manifestData)
        guard ["incomplete", "complete"].contains(manifest.status),
              (manifest.status == "complete") == (manifest.finishedAt != nil),
              try verify(
                  manifest: manifest, in: directory,
                  requireComplete: manifest.status == "complete"
              )
        else { throw SourceFailure.invalidArchive }
        return manifest
    }

    public static func verify(at directory: URL) throws -> SourceManifest {
        let manifest = try inspect(at: directory)
        guard manifest.status == "complete" else { throw SourceFailure.invalidArchive }
        return manifest
    }

    private static func verify(
        manifest: SourceManifest,
        in directory: URL,
        requireComplete: Bool
    ) throws -> Bool {
        guard manifest.schemaVersion == 1,
              ["bunq", "paynl"].contains(manifest.provider),
              (2000...2100).contains(manifest.partitionYear),
              !manifest.environment.isEmpty, !manifest.coverage.isEmpty,
              Set(manifest.streams.map(\.name)).count == manifest.streams.count
        else { return false }
        if manifest.status == "incomplete" && manifest.identityReconciliation != nil {
            return false
        }
        if let assessment = manifest.identityReconciliation,
           assessment != identityAssessment(for: manifest) {
            return false
        }
        if requireComplete {
            guard manifest.pages.count == manifest.streams.reduce(0, { $0 + $1.pages }),
                  manifest.provider != "paynl" || hasCompletePAYCoverage(manifest)
            else { return false }
        }
        let grouped = Dictionary(grouping: manifest.pages, by: \.stream)
        let completed = Dictionary(uniqueKeysWithValues: manifest.streams.map { ($0.name, $0) })
        var requests = Set<String>()
        var filenames = Set<String>()

        for (name, pages) in grouped {
            let ordered = pages.sorted { $0.page < $1.page }
            guard isKebabCase(name),
                  ordered.enumerated().allSatisfy({ $0.element.page == $0.offset + 1 }),
                  let scope = ordered.first?.scope, !scope.isEmpty,
                  ordered.allSatisfy({ $0.scope == scope }) else { return false }
            if requireComplete && completed[name] == nil { return false }
            if let stream = completed[name] {
                guard stream.scope == scope, stream.pages == pages.count,
                      stream.itemCount == pages.reduce(0, { $0 + $1.itemCount })
                else { return false }
            }
        }
        guard completed.keys.allSatisfy({ grouped[$0] != nil }) else { return false }

        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        for page in manifest.pages {
            let expected = "\(page.stream)/page-\(String(format: "%06d", page.page)).json"
            if let mismatch = page.detailMismatch {
                guard manifest.provider == "paynl", page.stream == "paynl-transaction-details",
                      page.itemCount == 1, !mismatch.expectedID.isEmpty,
                      !mismatch.observedID.isEmpty,
                      mismatch.expectedID != mismatch.observedID ||
                          (mismatch.expectedOrderID != nil &&
                           mismatch.expectedOrderID != mismatch.observedOrderID)
                else { return false }
                // Unresolved identity is recorded independently of byte completeness.
            }
            guard page.file == expected, page.itemCount >= 0,
                  page.path.hasPrefix("/"), !page.path.contains("//"),
                  filenames.insert(page.file).inserted,
                  requests.insert(readKey(path: page.path, query: page.query)).inserted
            else { return false }
            let url = directory.appendingPathComponent(page.file)
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.deletingLastPathComponent().deletingLastPathComponent() == resolvedDirectory
            else { return false }
            guard let data = try? Data(contentsOf: url),
                  data.count == page.bytes, sha256(data) == page.sha256
            else { return false }
        }
        return true
    }

    private static func writeManifest(_ manifest: SourceManifest, in directory: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        let target = directory.appendingPathComponent("manifest.json")
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isKebabCase(_ value: String) -> Bool {
        guard !value.isEmpty, value.first != "-", value.last != "-" else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) ||
            ($0.value >= 48 && $0.value <= 57) || $0.value == 45
        }
    }
}
