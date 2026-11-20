import Foundation
import PayNL

/// A bounded comparison of PAY. order-ID detail responses against fresh EX-ID
/// lookups. This is diagnostic evidence, not a change to the acquisition archive
/// or an authorization to reconcile any financial transaction.
public enum PayNLIdentityProbe {
    public struct Comparison: Codable, Sendable {
        public let originalDetailPage: Int
        public let expectedEXID: String
        public let expectedOrderID: String
        public let orderLookupEXID: String
        public let exLookupEXID: String
        public let exLookupOrderID: String?
        public let exIDMatchesListing: Bool
        public let orderIDMatchesListing: Bool
        public let exIDMatchesOrderLookup: Bool
        public let amountMatchesListing: Bool?
        public let currencyMatchesListing: Bool?
        public let statusMatchesListing: Bool?
        public let amountMatchesOrderLookup: Bool?
        public let currencyMatchesOrderLookup: Bool?
        public let statusMatchesOrderLookup: Bool?
        public let rawFile: String
        public let rawSHA256: String
        public let rawBytes: Int
    }

    public struct Report: Codable, Sendable {
        public let sourceRun: String
        public let sourceManifestSHA256: String
        public let totalArchivedMismatches: Int
        public let eligibleOrderLookups: Int
        public let selectedCount: Int
        public let startedAt: String
        public var finishedAt: String?
        public var status: String
        public var comparisons: [Comparison]
    }

    /// Reads only verified source evidence. Fresh responses and a resumable
    /// partial report are written into a new, exclusive diagnostic directory.
    /// The source archive is never reopened for mutation or rewritten.
    public static func run(
        sourceRun: URL,
        outputDirectory: URL,
        client: PayNL.Idefix.Client,
        capture: ReadCapture,
        sampleCount: Int = 5
    ) async throws -> Report {
        guard (1...10).contains(sampleCount) else { throw SourceFailure.invalidScope }
        let run = sourceRun.resolvingSymlinksInPath().standardizedFileURL
        let destination = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard destination != run,
              !destination.path.hasPrefix(run.path + "/"),
              !run.path.hasPrefix(destination.path + "/")
        else { throw SourceFailure.unsafeOutput }

        let manifest = try SourceArchive.verify(at: run)
        guard manifest.provider == "paynl",
              manifest.identityReconciliation?.status == .unresolved
        else { throw SourceFailure.invalidArchive }
        let originalManifestBytes = try Data(contentsOf: run.appendingPathComponent("manifest.json"))

        let eligible = manifest.pages.filter { page in
            guard page.stream == "paynl-transaction-details",
                  let mismatch = page.detailMismatch,
                  let orderID = mismatch.expectedOrderID,
                  !orderID.isEmpty
            else { return false }
            return page.path == "/v2/transactions/\(orderID)" &&
                mismatch.expectedID != mismatch.observedID &&
                mismatch.observedOrderID == orderID
        }.sorted { $0.page < $1.page }
        guard !eligible.isEmpty else { throw SourceFailure.invalidScope }

        // Decode the exact, SHA-verified listing pages, not a fresh listing that
        // could have changed since acquisition. Duplicate EX IDs are rejected.
        var summaries: [String: PayNL.Idefix.Summary] = [:]
        for page in manifest.pages.filter({ $0.stream == "paynl-transactions" }) {
            let data = try Data(contentsOf: run.appendingPathComponent(page.file))
            let listing = try JSONDecoder().decode(PayNL.Idefix.Page.self, from: data)
            for summary in listing.transactions {
                guard summaries.updateValue(summary, forKey: summary.id.raw) == nil else {
                    throw SourceFailure.duplicateRecord
                }
            }
        }
        let count = min(sampleCount, eligible.count)
        let selected: [SourcePageEvidence] = (0..<count).map { index in
            let position = count == 1 ? 0 : index * (eligible.count - 1) / (count - 1)
            return eligible[position]
        }
        for page in selected {
            guard let mismatch = page.detailMismatch,
                  let summary = summaries[mismatch.expectedID],
                  summary.orderId == mismatch.expectedOrderID
            else { throw SourceFailure.invalidArchive }
            let oldBody = try Data(contentsOf: run.appendingPathComponent(page.file))
            let oldDetail = try JSONDecoder().decode(PayNL.Idefix.Transaction.self, from: oldBody)
            guard oldDetail.id.raw == mismatch.observedID,
                  oldDetail.orderId == mismatch.observedOrderID
            else { throw SourceFailure.invalidArchive }
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw SourceFailure.unsafeOutput }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        var report = Report(
            sourceRun: run.path,
            sourceManifestSHA256: SourceArchive.sha256(originalManifestBytes),
            totalArchivedMismatches: manifest.pages.filter { $0.detailMismatch != nil }.count,
            eligibleOrderLookups: eligible.count,
            selectedCount: count,
            startedAt: Date().ISO8601Format(),
            finishedAt: nil,
            status: "in_progress",
            comparisons: []
        )
        try write(report: report, to: destination)

        for page in selected {
            guard let mismatch = page.detailMismatch,
                  let orderID = mismatch.expectedOrderID,
                  let summary = summaries[mismatch.expectedID]
            else { throw SourceFailure.invalidArchive }
            let oldBody = try Data(contentsOf: run.appendingPathComponent(page.file))
            let oldDetail = try JSONDecoder().decode(PayNL.Idefix.Transaction.self, from: oldBody)

            // The SDK validates the HTTP response and decodes it before bytes
            // are taken from ReadCapture. Only one verified GET can be pending.
            let expectedID = try PayNL.Idefix.Transaction.ID(mismatch.expectedID)
            let fresh = try await client.transactions.get(expectedID)
            let raw = try await capture.take(expectedPath: "/v2/transactions/\(expectedID.raw)")
            guard raw.query == nil, !raw.body.isEmpty else { throw SourceFailure.invalidCapture }
            let rawName = "ex-lookup-page-\(String(format: "%06d", page.page)).json"
            let rawFile = destination.appendingPathComponent(rawName)
            guard !fm.fileExists(atPath: rawFile.path) else { throw SourceFailure.unsafeOutput }
            try raw.body.write(to: rawFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawFile.path)

            report.comparisons.append(Comparison(
                originalDetailPage: page.page,
                expectedEXID: mismatch.expectedID,
                expectedOrderID: orderID,
                orderLookupEXID: oldDetail.id.raw,
                exLookupEXID: fresh.id.raw,
                exLookupOrderID: fresh.orderId,
                exIDMatchesListing: fresh.id == summary.id,
                orderIDMatchesListing: fresh.orderId == orderID,
                exIDMatchesOrderLookup: fresh.id == oldDetail.id,
                amountMatchesListing: same(summary.amount?.value, fresh.amount?.value),
                currencyMatchesListing: same(summary.amount?.currency?.raw, fresh.amount?.currency?.raw),
                statusMatchesListing: same(status(summary.status), status(fresh.status)),
                amountMatchesOrderLookup: same(oldDetail.amount?.value, fresh.amount?.value),
                currencyMatchesOrderLookup: same(oldDetail.amount?.currency?.raw, fresh.amount?.currency?.raw),
                statusMatchesOrderLookup: same(status(oldDetail.status), status(fresh.status)),
                rawFile: rawName,
                rawSHA256: SourceArchive.sha256(raw.body),
                rawBytes: raw.body.count
            ))
            try write(report: report, to: destination)
        }

        // Assert that the source manifest and every archived body are unchanged.
        guard try Data(contentsOf: run.appendingPathComponent("manifest.json")) == originalManifestBytes
        else { throw SourceFailure.invalidArchive }
        _ = try SourceArchive.verify(at: run)
        report.status = "complete"
        report.finishedAt = Date().ISO8601Format()
        try write(report: report, to: destination)
        return report
    }

    private struct StatusFields: Equatable {
        let code: Int?
        let action: String?
        let phase: String?
    }

    private static func status(_ value: PayNL.Idefix.Transaction.Status?) -> StatusFields? {
        guard let value,
              value.code != nil || value.action != nil || value.phase != nil
        else { return nil }
        return StatusFields(code: value.code, action: value.action, phase: value.phase)
    }

    private static func same<T: Equatable>(_ first: T?, _ second: T?) -> Bool? {
        guard let first, let second else { return nil }
        return first == second
    }

    private static func write(report: Report, to directory: URL) throws {
        let target = directory.appendingPathComponent("report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
