import Bunq
import Foundation

/// Catalogs the monetary-account and payment endpoints already captured by
/// SourceIngestion.bunq. No network, statement, or accounting semantics implied.
public enum BunqSourceCatalog {
    private struct Listing<Element: Decodable>: Decodable {
        let Response: [Element]
    }

    public static func build(sourceRun: URL, accountScope: String) throws -> SourceCatalog {
        guard SourceCatalog.validAccountScope(accountScope) else {
            throw SourceFailure.invalidScope
        }

        let source = sourceRun.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try SourceArchive.verify(at: source)
        guard manifest.provider == "bunq",
              ["sandbox", "production"].contains(manifest.environment),
              let accountStream = manifest.streams.first(where: { $0.name == "bunq-accounts" }),
              accountStream.pages > 0,
              Int64(accountStream.scope).map({ $0 > 0 }) == true
        else { throw SourceFailure.invalidScope }

        let userID = accountStream.scope
        let manifestFile = source.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifestFile)
        let manifestSHA = SourceArchive.sha256(originalManifest)
        let decoder = JSONDecoder()
        var observations: [String: SourceObservation] = [:]
        var accountIDs = Set<String>()
        let pages = manifest.pages.sorted {
            $0.stream == $1.stream ? $0.page < $1.page : $0.stream < $1.stream
        }

        func identity(_ kind: SourceObservation.Kind, accountID: String, recordID: String) throws -> String {
            let tuple = [
                "bunq", manifest.environment, accountScope, kind.rawValue,
                userID, accountID, recordID
            ]
            return "source-v1-" + SourceArchive.sha256(try JSONEncoder().encode(tuple))
        }

        func bytes(_ page: SourcePageEvidence) throws -> Data {
            let value = try Data(contentsOf: source.appendingPathComponent(page.file))
            guard value.count == page.bytes, SourceArchive.sha256(value) == page.sha256 else {
                throw SourceFailure.invalidArchive
            }
            return value
        }

        func reference(_ page: SourcePageEvidence, _ index: Int) -> SourceReference {
            SourceReference(
                manifestSHA256: manifestSHA, stream: page.stream, page: page.page,
                file: page.file, pageSHA256: page.sha256, recordIndex: index
            )
        }

        func insert(
            kind: SourceObservation.Kind, recordID: String, accountID: String,
            parentID: String, page: SourcePageEvidence, index: Int
        ) throws {
            guard !recordID.isEmpty, index >= 0, index < page.itemCount else {
                throw SourceFailure.invalidArchive
            }
            let key = try identity(kind, accountID: accountID, recordID: recordID)
            guard observations[key] == nil else { throw SourceFailure.duplicateRecord }
            observations[key] = SourceObservation(
                key: key, kind: kind, externalID: recordID,
                parentExternalID: parentID, orderID: nil, statusCode: nil,
                statusAction: nil, statusPhase: nil, detailObservedID: nil,
                detailIdentity: .not_applicable, references: [reference(page, index)]
            )
        }

        let accountsPath = "/v1/user/\(userID)/monetary-account"
        for page in pages where page.stream == "bunq-accounts" {
            guard page.scope == userID, page.path == accountsPath else {
                throw SourceFailure.invalidArchive
            }
            let listing = try decoder.decode(Listing<Bunq.MonetaryAccount>.self, from: bytes(page))
            guard listing.Response.count == page.itemCount else {
                throw SourceFailure.invalidArchive
            }
            for (index, account) in listing.Response.enumerated() {
                let id = String(account.id.raw)
                guard accountIDs.insert(id).inserted else { throw SourceFailure.duplicateRecord }
                try insert(kind: .bunq_account, recordID: id, accountID: id,
                           parentID: userID, page: page, index: index)
            }
        }
        guard accountIDs.count == accountStream.itemCount else {
            throw SourceFailure.invalidArchive
        }

        let paymentStreams = manifest.streams.filter { $0.name.hasPrefix("bunq-payments-account-") }
        guard manifest.streams.count == paymentStreams.count + 1,
              paymentStreams.count == accountIDs.count,
              Set(paymentStreams.map(\.scope)) == accountIDs,
              paymentStreams.allSatisfy({ $0.name == "bunq-payments-account-\($0.scope)" && $0.pages > 0 })
        else { throw SourceFailure.invalidArchive }

        var paymentCounts: [String: Int] = [:]
        for page in pages where page.stream != "bunq-accounts" {
            let accountID = page.scope
            let expectedStream = "bunq-payments-account-\(accountID)"
            let expectedPath = "\(accountsPath)/\(accountID)/payment"
            guard accountIDs.contains(accountID), page.stream == expectedStream,
                  page.path == expectedPath else { throw SourceFailure.invalidArchive }
            let listing = try decoder.decode(Listing<Bunq.Payment>.self, from: bytes(page))
            guard listing.Response.count == page.itemCount else {
                throw SourceFailure.invalidArchive
            }
            for (index, payment) in listing.Response.enumerated() {
                guard String(payment.monetary_account_id.raw) == accountID else {
                    throw SourceFailure.invalidArchive
                }
                try insert(kind: .bunq_payment, recordID: String(payment.id.raw),
                           accountID: accountID, parentID: accountID,
                           page: page, index: index)
                paymentCounts[accountID, default: 0] += 1
            }
        }
        guard paymentStreams.allSatisfy({ paymentCounts[$0.scope, default: 0] == $0.itemCount }),
              try Data(contentsOf: manifestFile) == originalManifest
        else { throw SourceFailure.invalidArchive }
        _ = try SourceArchive.verify(at: source)

        let streams = manifest.streams.sorted { $0.name < $1.name }.map {
            SourceCoverage.Stream(
                name: $0.name, scope: $0.scope, pages: $0.pages, items: $0.itemCount
            )
        }
        return SourceCatalog(
            schemaVersion: 1, provider: manifest.provider, environment: manifest.environment,
            accountScope: accountScope, sourceRun: source.path, manifestSHA256: manifestSHA,
            coverage: SourceCoverage(
                acquisition: "complete", historicalCoverage: "unknown",
                providerScopeDescription: manifest.coverage, streams: streams
            ),
            observations: observations.values.sorted { $0.key < $1.key }
        )
    }
}
