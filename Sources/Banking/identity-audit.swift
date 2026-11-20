import Foundation
import PayNL

/// Offline comparison of every PAY. browse transaction against its corresponding
/// archived detail. A matching order ID or amount does not prove EX-ID identity.
/// Neither archived evidence nor reconciliation status is ever changed.
public enum PayNLIdentityAudit {
    public enum Result: String, Codable, Sendable {
        case matched
        case different
        case unavailable
    }

    public enum Classification: String, Codable, Sendable {
        case no_identity_discrepancy
        /// The provider returned the matching order ID in the detail `id` field
        /// for a cancelled/expired EX record. Browse EX identity stays unresolved.
        case order_id_returned_as_transaction_id
        case identifier_only_financial_fields_match
        case identifier_only_financial_fields_unavailable
        case financial_difference
        case other_field_difference
        case order_difference
        case inconsistent_archive_metadata
    }

    public enum TimestampRelationship: String, Codable, Sendable {
        case same_instant
        case detail_one_second_earlier
        case different
        case unavailable
        case unparseable
    }

    public struct Field: Codable, Sendable {
        public let name: String
        public let result: Result
        public let browseValue: String?
        public let detailValue: String?
    }

    public struct Record: Codable, Sendable {
        public let detailPage: Int
        public let browseEXID: String
        public let detailEXID: String
        public let browseOrderID: String?
        public let detailOrderID: String?
        public let requestedPath: String
        public let sourceFile: String
        public let sourceSHA256: String
        public let flaggedInManifest: Bool
        public let metadataAgreesWithBodies: Bool
        public let detailEXIDAppearsInBrowse: Bool
        public let classification: Classification
        /// Comparison of parsed instants, not raw ISO-8601 text.
        public let createdAtRelationship: TimestampRelationship
        public let createdAtDeltaSeconds: Double?
        public let fields: [Field]
    }

    public struct FieldCounts: Codable, Sendable {
        public var matched = 0
        public var different = 0
        public var unavailable = 0
    }

    public struct Report: Codable, Sendable {
        /// Version 2 adds the empirical response-pattern and normalized-time interpretation.
        public let schemaVersion: Int
        public let sourceRun: String
        public let sourceManifestSHA256: String
        public let auditedAt: String
        public let browseCount: Int
        public let detailCount: Int
        public let archivedFlaggedCount: Int
        public let classificationCounts: [String: Int]
        public let fieldCountsOnFlaggedRecords: [String: FieldCounts]
        public let timestampRelationshipCountsOnFlaggedRecords: [String: Int]
        public let records: [Record]
    }

    /// Validates every archived SHA-256 and the one-to-one browse/detail page
    /// mapping before writing a separate, private report. Never makes HTTP calls.
    public static func run(sourceRun: URL, outputDirectory: URL) throws -> Report {
        let source = sourceRun.resolvingSymlinksInPath().standardizedFileURL
        let output = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard output != source,
              !output.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(output.path + "/")
        else { throw SourceFailure.unsafeOutput }

        let manifest = try SourceArchive.verify(at: source)
        guard manifest.provider == "paynl" else { throw SourceFailure.invalidScope }
        let manifestBytes = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let manifestDigest = SourceArchive.sha256(manifestBytes)

        var summaries: [String: PayNL.Idefix.Summary] = [:]
        for page in manifest.pages.filter({ $0.stream == "paynl-transactions" }) {
            let bytes = try Data(contentsOf: source.appendingPathComponent(page.file))
            let listing = try JSONDecoder().decode(PayNL.Idefix.Page.self, from: bytes)
            guard listing.count == listing.transactions.count,
                  listing.count == page.itemCount
            else { throw SourceFailure.invalidArchive }
            for item in listing.transactions {
                guard summaries.updateValue(item, forKey: item.id.raw) == nil else {
                    throw SourceFailure.duplicateRecord
                }
            }
        }
        let ids = summaries.keys.sorted()
        let details = manifest.pages.filter({ $0.stream == "paynl-transaction-details" })
            .sorted { $0.page < $1.page }
        guard details.count == ids.count,
              details.enumerated().allSatisfy({ $0.element.page == $0.offset + 1 }),
              manifest.streams.first(where: { $0.name == "paynl-transactions" })?.itemCount == ids.count,
              manifest.streams.first(where: { $0.name == "paynl-transaction-details" })?.itemCount == ids.count
        else { throw SourceFailure.invalidArchive }

        var records: [Record] = []
        var classifications: [String: Int] = [:]
        var fieldsOnFlagged: [String: FieldCounts] = [:]
        var timestampsOnFlagged: [String: Int] = [:]
        let browsedIDs = Set(ids)
        for (index, page) in details.enumerated() {
            guard let summary = summaries[ids[index]], page.itemCount == 1 else {
                throw SourceFailure.invalidArchive
            }
            let body = try Data(contentsOf: source.appendingPathComponent(page.file))
            let detail = try JSONDecoder().decode(PayNL.Idefix.Transaction.self, from: body)
            let expectedID = summary.id.raw
            let orderID = summary.orderId
            let identityDiffers = expectedID != detail.id.raw
            let orderDiffers = orderID.map { $0 != detail.orderId } ?? false
            let expectedFlag = identityDiffers || orderDiffers
            let annotated = page.detailMismatch
            let metadataAgrees = expectedFlag == (annotated != nil) && (
                annotated == nil || (
                    annotated?.expectedID == expectedID &&
                    annotated?.observedID == detail.id.raw &&
                    annotated?.expectedOrderID == orderID &&
                    annotated?.observedOrderID == detail.orderId &&
                    annotated?.observedIDInBrowse == browsedIDs.contains(detail.id.raw)
                )
            )
            let expectedPath = "/v2/transactions/\(expectedID)"
            let orderPath = orderID.map { "/v2/transactions/\($0)" }
            guard page.query == nil,
                  page.path == expectedPath || (orderPath != nil && page.path == orderPath)
            else { throw SourceFailure.invalidArchive }

            let (createdAt, createdAtRelationship, createdAtDelta) = timestampField(
                summary.createdAt, detail.createdAt
            )
            let fields: [Field] = [
                field("order_id", orderID, detail.orderId),
                field("amount_minor", summary.amount.map { String($0.value) }, detail.amount.map { String($0.value) }),
                field("currency", summary.amount?.currency?.raw, detail.amount?.currency?.raw),
                field("status", status(summary.status), status(detail.status)),
                field("refunded_amount_minor", summary.amountRefunded.map { String($0.value) }, detail.amountRefunded.map { String($0.value) }),
                field("refunded_currency", summary.amountRefunded?.currency?.raw, detail.amountRefunded?.currency?.raw),
                field("reference", summary.reference, detail.reference),
                field("description", summary.description, detail.description),
                createdAt,
                field("completed_date", summary.completedDate, detail.completedDate),
            ]
            let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.result) })
            let financialNames = ["amount_minor", "currency", "status", "refunded_amount_minor", "refunded_currency"]
            let critical = ["amount_minor", "currency", "status"]
            let financialDiffers = financialNames.contains { byName[$0] == .different }
            let otherDiffers = ["reference", "description", "created_at", "completed_date"].contains {
                byName[$0] == .different
            }
            let terminalCancellation: Bool
            switch summary.status?.code {
            case -80:
                terminalCancellation = summary.status?.action?.uppercased() == "CANCEL" &&
                    summary.status?.phase?.uppercased() == "EXPIRED"
            case -90:
                terminalCancellation = summary.status?.action?.uppercased() == "CANCEL" &&
                    summary.status?.phase?.uppercased() == "CANCELLED"
            default:
                terminalCancellation = false
            }
            // An *observed* provider response shape, not EX-ID equivalence.
            // Do not accept it if financial/descriptive fields contradict the
            // listing, if status is not terminal, or if the timestamps diverge.
            let orderInIDField = identityDiffers && annotated != nil &&
                expectedID.hasPrefix("EX-") && detail.idRepresentation == .order_id &&
                orderID != nil && detail.id.raw == orderID && detail.orderId == orderID &&
                !browsedIDs.contains(detail.id.raw)
            let observedPattern = orderInIDField && terminalCancellation &&
                byName["status"] == .matched &&
                critical.allSatisfy({ byName[$0] == .matched }) &&
                ["refunded_amount_minor", "refunded_currency", "reference", "description"].allSatisfy({
                    byName[$0] != .different
                }) &&
                (createdAtRelationship == .same_instant ||
                 createdAtRelationship == .detail_one_second_earlier)
            let classification: Classification
            if !metadataAgrees {
                classification = .inconsistent_archive_metadata
            } else if byName["order_id"] == .different {
                classification = .order_difference
            } else if financialDiffers {
                classification = .financial_difference
            } else if observedPattern {
                classification = .order_id_returned_as_transaction_id
            } else if otherDiffers {
                classification = .other_field_difference
            } else if identityDiffers || expectedFlag {
                classification = critical.allSatisfy({ byName[$0] == .matched }) &&
                    byName["order_id"] == .matched
                    ? .identifier_only_financial_fields_match
                    : .identifier_only_financial_fields_unavailable
            } else {
                classification = .no_identity_discrepancy
            }
            let record = Record(
                detailPage: page.page,
                browseEXID: expectedID, detailEXID: detail.id.raw,
                browseOrderID: orderID, detailOrderID: detail.orderId,
                requestedPath: page.path, sourceFile: page.file,
                sourceSHA256: page.sha256, flaggedInManifest: annotated != nil,
                metadataAgreesWithBodies: metadataAgrees,
                detailEXIDAppearsInBrowse: browsedIDs.contains(detail.id.raw),
                classification: classification,
                createdAtRelationship: createdAtRelationship,
                createdAtDeltaSeconds: createdAtDelta,
                fields: fields
            )
            records.append(record)
            classifications[classification.rawValue, default: 0] += 1
            if annotated != nil {
                timestampsOnFlagged[createdAtRelationship.rawValue, default: 0] += 1
                for comparison in fields {
                    var counts = fieldsOnFlagged[comparison.name, default: FieldCounts()]
                    switch comparison.result {
                    case .matched: counts.matched += 1
                    case .different: counts.different += 1
                    case .unavailable: counts.unavailable += 1
                    }
                    fieldsOnFlagged[comparison.name] = counts
                }
            }
        }
        let flaggedCount = records.filter(\.flaggedInManifest).count
        guard flaggedCount == manifest.pages.filter({ $0.detailMismatch != nil }).count,
              manifest.identityReconciliation?.discrepancyCount == nil ||
                  manifest.identityReconciliation?.discrepancyCount == flaggedCount
        else { throw SourceFailure.invalidArchive }
        let report = Report(
            schemaVersion: 2,
            sourceRun: source.path, sourceManifestSHA256: manifestDigest,
            auditedAt: Date().ISO8601Format(), browseCount: ids.count,
            detailCount: details.count,
            archivedFlaggedCount: records.filter(\.flaggedInManifest).count,
            classificationCounts: classifications,
            fieldCountsOnFlaggedRecords: fieldsOnFlagged,
            timestampRelationshipCountsOnFlaggedRecords: timestampsOnFlagged,
            records: records
        )

        // Verify that no source body or manifest changed during the audit.
        guard try Data(contentsOf: source.appendingPathComponent("manifest.json")) == manifestBytes
        else { throw SourceFailure.invalidArchive }
        _ = try SourceArchive.verify(at: source)

        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw SourceFailure.unsafeOutput }
        try fm.createDirectory(at: output, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        let reportURL = output.appendingPathComponent("report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        return report
    }

    private static func field(_ name: String, _ browse: String?, _ detail: String?) -> Field {
        let result: Result
        if let browse, let detail {
            result = browse == detail ? .matched : .different
        } else {
            result = .unavailable
        }
        return Field(name: name, result: result, browseValue: browse, detailValue: detail)
    }

    /// Compare ISO-8601 instants rather than textual offsets. A one-second
    /// difference remains explicitly different and is never rounded away.
    private static func timestampField(
        _ browse: String?, _ detail: String?
    ) -> (Field, TimestampRelationship, Double?) {
        guard let browse, let detail else {
            return (field("created_at", browse, detail), .unavailable, nil)
        }
        guard let a = date(browse), let b = date(detail) else {
            return (field("created_at", browse, detail), .unparseable, nil)
        }
        let delta = b.timeIntervalSince(a)
        let relationship: TimestampRelationship
        if abs(delta) < 0.000001 {
            relationship = .same_instant
        } else if abs(delta + 1) < 0.000001 {
            relationship = .detail_one_second_earlier
        } else {
            relationship = .different
        }
        return (
            Field(name: "created_at", result: relationship == .same_instant ? .matched : .different,
                  browseValue: browse, detailValue: detail),
            relationship, delta
        )
    }

    private static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        if let parsed = parser.date(from: value) { return parsed }
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value)
    }

    private static func status(_ value: PayNL.Idefix.Transaction.Status?) -> String? {
        guard let value,
              value.code != nil || value.action != nil || value.phase != nil
        else { return nil }
        // JSON-encode the optional components to prevent delimiter ambiguity.
        let parts: [String?] = [value.code.map(String.init), value.action, value.phase]
        let encoder = JSONEncoder()
        return (try? encoder.encode(parts)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
