import Foundation
import PayNL

/// A specific row or detail body within a SHA-256-verified acquisition.
/// This is provenance, not the identity of the underlying financial event.
public struct SourceReference: Codable, Sendable, Hashable {
    public let manifestSHA256: String
    public let stream: String
    public let page: Int
    public let file: String
    public let pageSHA256: String
    public let recordIndex: Int
}

public struct SourceObservation: Codable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case paynl_transaction
        case paynl_clearing
        case paynl_clearing_line
        case paynl_settlement
        case bunq_account
        case bunq_payment
    }

    public enum DetailIdentity: String, Codable, Sendable {
        case not_applicable
        case matched
        case unresolved
    }

    /// SHA-256 of a structured, provider-/tenant-scoped identity tuple.
    /// Never depends on a fiscal year, acquisition run, or filename.
    public let key: String
    public let kind: Kind
    public let externalID: String
    public let parentExternalID: String?
    public let orderID: String?
    public let statusCode: Int?
    public let statusAction: String?
    public let statusPhase: String?
    public var detailObservedID: String?
    public var detailIdentity: DetailIdentity
    public var references: [SourceReference]
}

public struct SourceCoverage: Codable, Sendable {
    public struct Stream: Codable, Sendable {
        public let name: String
        public let scope: String
        public let pages: Int
        public let items: Int
    }

    public let acquisition: String
    public let historicalCoverage: String
    public let providerScopeDescription: String
    public let streams: [Stream]
}

public struct SourceCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let provider: String
    public let environment: String
    public let accountScope: String
    public let sourceRun: String
    public let manifestSHA256: String
    public let coverage: SourceCoverage
    public let observations: [SourceObservation]
}

/// Builds a stable, offline logical index. Provider responses and manifests are
/// read-only; a catalog is not a financial reconciliation or an .ec transaction.
public enum PayNLSourceCatalog {
    private struct ClearingsPage: Decodable {
        let count: Int
        let clearings: [PayNL.GMS.Clearing]
    }

    private struct LinesPage: Decodable {
        let count: Int
        let clearingLines: [PayNL.GMS.ClearingLine]
    }

    private struct SettlementsPage: Decodable {
        let count: Int
        let settlements: [PayNL.GMS.Settlement]
    }

    public static func build(sourceRun: URL, accountScope: String) throws -> SourceCatalog {
        guard SourceCatalog.validAccountScope(accountScope) else {
            throw SourceFailure.invalidScope
        }

        let source = sourceRun.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try SourceArchive.verify(at: source)
        guard manifest.provider == "paynl" else { throw SourceFailure.invalidScope }
        let originalManifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let manifestSHA = SourceArchive.sha256(originalManifest)
        let decoder = JSONDecoder()
        var observations: [String: SourceObservation] = [:]
        var transactionSummaries: [String: PayNL.Idefix.Summary] = [:]
        var clearingIDs = Set<String>()

        func identity(_ kind: SourceObservation.Kind, _ externalID: String, parent: String? = nil) throws -> String {
            let tuple = ["paynl", manifest.environment, accountScope, kind.rawValue, parent ?? "", externalID]
            return "source-v1-" + SourceArchive.sha256(try JSONEncoder().encode(tuple))
        }

        func bytes(_ page: SourcePageEvidence) throws -> Data {
            let value = try Data(contentsOf: source.appendingPathComponent(page.file))
            guard value.count == page.bytes, SourceArchive.sha256(value) == page.sha256
            else { throw SourceFailure.invalidArchive }
            return value
        }

        func reference(_ page: SourcePageEvidence, _ index: Int) -> SourceReference {
            SourceReference(
                manifestSHA256: manifestSHA, stream: page.stream, page: page.page,
                file: page.file, pageSHA256: page.sha256, recordIndex: index
            )
        }

        func insert(
            _ kind: SourceObservation.Kind, id: String, parent: String? = nil,
            orderID: String? = nil, status: PayNL.Idefix.Transaction.Status? = nil,
            page: SourcePageEvidence, index: Int
        ) throws {
            guard !id.isEmpty, index >= 0, index < page.itemCount else {
                throw SourceFailure.invalidArchive
            }
            let key = try identity(kind, id, parent: parent)
            guard observations[key] == nil else { throw SourceFailure.duplicateRecord }
            observations[key] = SourceObservation(
                key: key, kind: kind, externalID: id, parentExternalID: parent,
                orderID: orderID, statusCode: status?.code,
                statusAction: status?.action, statusPhase: status?.phase,
                detailObservedID: nil, detailIdentity: .not_applicable,
                references: [reference(page, index)]
            )
        }

        func streamOrder(_ name: String) -> Int {
            switch name {
            case "paynl-clearings": return 0
            case "paynl-transactions": return 1
            case "paynl-settlements": return 2
            case _ where name.hasPrefix("paynl-clearing-lines-"): return 3
            default: return 4
            }
        }
        let pages = manifest.pages.sorted {
            let lhs = streamOrder($0.stream)
            let rhs = streamOrder($1.stream)
            if lhs != rhs { return lhs < rhs }
            return $0.stream == $1.stream ? $0.page < $1.page : $0.stream < $1.stream
        }
        for page in pages {
            switch page.stream {
            case "paynl-transactions":
                let listing = try decoder.decode(PayNL.Idefix.Page.self, from: bytes(page))
                guard listing.transactions.count == listing.count,
                      listing.count == page.itemCount else { throw SourceFailure.invalidArchive }
                for (index, item) in listing.transactions.enumerated() {
                    guard transactionSummaries.updateValue(item, forKey: item.id.raw) == nil else {
                        throw SourceFailure.duplicateRecord
                    }
                    try insert(.paynl_transaction, id: item.id.raw, orderID: item.orderId,
                               status: item.status, page: page, index: index)
                }

            case "paynl-clearings":
                let listing = try decoder.decode(ClearingsPage.self, from: bytes(page))
                guard listing.count == page.itemCount,
                      listing.clearings.count == listing.count else { throw SourceFailure.invalidArchive }
                for (index, item) in listing.clearings.enumerated() {
                    guard clearingIDs.insert(item.id.raw).inserted else { throw SourceFailure.duplicateRecord }
                    try insert(.paynl_clearing, id: item.id.raw, page: page, index: index)
                }

            case "paynl-settlements":
                let listing = try decoder.decode(SettlementsPage.self, from: bytes(page))
                guard listing.count == page.itemCount,
                      listing.settlements.count == listing.count else { throw SourceFailure.invalidArchive }
                for (index, item) in listing.settlements.enumerated() {
                    try insert(.paynl_settlement, id: item.code.raw, page: page, index: index)
                }

            case let name where name.hasPrefix("paynl-clearing-lines-"):
                let listing = try decoder.decode(LinesPage.self, from: bytes(page))
                guard clearingIDs.contains(page.scope), listing.count == page.itemCount,
                      listing.clearingLines.count == listing.count else { throw SourceFailure.invalidArchive }
                for (index, item) in listing.clearingLines.enumerated() {
                    try insert(.paynl_clearing_line, id: item.code, parent: page.scope,
                               page: page, index: index)
                }

            case "paynl-transaction-details", "paynl-clearing-details":
                break
            default:
                throw SourceFailure.invalidArchive
            }
        }

        let sortedTransactionIDs = transactionSummaries.keys.sorted()
        let transactionDetails = pages.filter { $0.stream == "paynl-transaction-details" }
        guard transactionDetails.count == sortedTransactionIDs.count else {
            throw SourceFailure.invalidArchive
        }
        for (offset, page) in transactionDetails.enumerated() {
            guard page.page == offset + 1, page.itemCount == 1,
                  let summary = transactionSummaries[sortedTransactionIDs[offset]]
            else { throw SourceFailure.invalidArchive }
            let prefix = "/v2/transactions/"
            guard page.query == nil, page.path.hasPrefix(prefix) else {
                throw SourceFailure.invalidArchive
            }
            let locator = String(page.path.dropFirst(prefix.count)).removingPercentEncoding
            guard locator == summary.id.raw ||
                  (summary.orderId != nil && locator == summary.orderId) else {
                throw SourceFailure.invalidArchive
            }
            let detail = try decoder.decode(PayNL.Idefix.Transaction.self, from: bytes(page))
            let mismatch = detail.id != summary.id ||
                (summary.orderId.map { $0 != detail.orderId } ?? false)
            guard (page.detailMismatch != nil) == mismatch else { throw SourceFailure.invalidArchive }
            if let annotated = page.detailMismatch {
                guard annotated.expectedID == summary.id.raw,
                      annotated.observedID == detail.id.raw,
                      annotated.expectedOrderID == summary.orderId,
                      annotated.observedOrderID == detail.orderId
                else { throw SourceFailure.invalidArchive }
            }
            let key = try identity(.paynl_transaction, summary.id.raw)
            guard var existing = observations[key] else { throw SourceFailure.invalidArchive }
            existing.detailIdentity = mismatch ? .unresolved : .matched
            existing.detailObservedID = detail.id.raw
            existing.references.append(reference(page, 0))
            observations[key] = existing
        }

        let clearingDetails = pages.filter { $0.stream == "paynl-clearing-details" }
        guard clearingDetails.count == clearingIDs.count else { throw SourceFailure.invalidArchive }
        var seenClearingDetails = Set<String>()
        for page in clearingDetails {
            guard page.itemCount == 1 else { throw SourceFailure.invalidArchive }
            let detail = try decoder.decode(PayNL.GMS.Clearing.self, from: bytes(page))
            guard clearingIDs.contains(detail.id.raw),
                  seenClearingDetails.insert(detail.id.raw).inserted,
                  page.path.hasPrefix("/v2/clearings/"),
                  String(page.path.dropFirst("/v2/clearings/".count)).removingPercentEncoding == detail.id.raw else {
                throw SourceFailure.invalidArchive
            }
            let key = try identity(.paynl_clearing, detail.id.raw)
            guard var existing = observations[key] else { throw SourceFailure.invalidArchive }
            existing.references.append(reference(page, 0))
            observations[key] = existing
        }

        let counts = Dictionary(grouping: observations.values, by: \.kind)
        let streams = manifest.streams.sorted { $0.name < $1.name }.map {
            SourceCoverage.Stream(name: $0.name, scope: $0.scope, pages: $0.pages, items: $0.itemCount)
        }
        let expectedCounts: [(SourceObservation.Kind, Int)] = [
            (.paynl_transaction, manifest.streams.first(where: { $0.name == "paynl-transactions" })?.itemCount ?? -1),
            (.paynl_clearing, manifest.streams.first(where: { $0.name == "paynl-clearings" })?.itemCount ?? -1),
            (.paynl_settlement, manifest.streams.first(where: { $0.name == "paynl-settlements" })?.itemCount ?? -1),
            (.paynl_clearing_line, manifest.streams.filter { $0.name.hasPrefix("paynl-clearing-lines-") }
                .reduce(0, { $0 + $1.itemCount })),
        ]
        guard expectedCounts.allSatisfy({ (counts[$0.0]?.count ?? 0) == $0.1 }),
              try Data(contentsOf: source.appendingPathComponent("manifest.json")) == originalManifest
        else { throw SourceFailure.invalidArchive }
        _ = try SourceArchive.verify(at: source)

        return SourceCatalog(
            schemaVersion: 1, provider: manifest.provider, environment: manifest.environment,
            accountScope: accountScope, sourceRun: source.path, manifestSHA256: manifestSHA,
            coverage: SourceCoverage(
                acquisition: "complete", historicalCoverage: "unknown",
                providerScopeDescription: manifest.coverage, streams: streams
            ),
            observations: observations.values.map { item in
                var copy = item
                copy.references.sort {
                    if $0.stream != $1.stream { return $0.stream < $1.stream }
                    if $0.page != $1.page { return $0.page < $1.page }
                    return $0.recordIndex < $1.recordIndex
                }
                return copy
            }.sorted { $0.key < $1.key }
        )
    }

    /// Refuse overwrite and output paths that are ancestors/descendants of raw evidence.
    public static func write(_ catalog: SourceCatalog, to outputDirectory: URL) throws {
        try SourceCatalogWriter.write(catalog, to: outputDirectory)
    }
}

/// Persistence for provider-neutral source catalogs, never inside raw archives.
public enum SourceCatalogWriter {
    public static func write(_ catalog: SourceCatalog, to outputDirectory: URL) throws {
        let source = URL(fileURLWithPath: catalog.sourceRun, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let output = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard output != source,
              !output.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(output.path + "/"),
              !FileManager.default.fileExists(atPath: output.path)
        else { throw SourceFailure.unsafeOutput }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let catalogBytes = try encoder.encode(catalog)
        let coverageBytes = try encoder.encode(catalog.coverage)
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        for (name, body) in [("observations.json", catalogBytes), ("coverage.json", coverageBytes)] {
            let url = output.appendingPathComponent(name)
            try body.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}


extension SourceCatalog {
    static func validAccountScope(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy({
            (48...57).contains(Int($0.value)) ||
            (65...90).contains(Int($0.value)) ||
            (97...122).contains(Int($0.value)) ||
            $0 == "-" || $0 == "_" || $0 == "."
        })
    }
}
