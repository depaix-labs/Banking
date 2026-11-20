import Bunq
import Foundation
import PayNL

public enum SourceIngestion {
    private static let maximumPages = 10_000

    /// All pages available through the monetary-account and payment endpoints.
    /// This is not a complete bank-statement claim: other Bunq movement types are excluded.
    public static func bunq(
        client: Bunq.Client,
        capture: ReadCapture,
        archive: SourceArchive
    ) async throws {
        guard let user = await client.authenticatedUser?.id else {
            throw SourceFailure.invalidScope
        }
        let accountPath = "/v1/user/\(user.raw)/monetary-account"
        var cursor: Bunq.Pagination.Cursor?
        var accountIDs = Set<Bunq.MonetaryAccount.ID>()
        var seenQueries = Set<String>()
        var accountPage = 0
        repeat {
            guard accountPage < maximumPages else { throw SourceFailure.incompletePagination }
            let response = try await client.user(user).accounts.list(cursor: cursor)
            let captured = try await capture.take(expectedPath: accountPath)
            try acceptUniqueQuery(captured, into: &seenQueries)
            accountPage += 1
            for account in response.items {
                guard accountIDs.insert(account.id).inserted else {
                    throw SourceFailure.duplicateRecord
                }
            }
            try await archive.append(
                stream: "bunq-accounts", scope: String(user.raw),
                page: accountPage, captured: captured, itemCount: response.items.count
            )
            cursor = response.pagination.older
        } while cursor != nil
        try await archive.finishStream(
            name: "bunq-accounts", scope: String(user.raw), itemCount: accountIDs.count
        )

        for accountID in accountIDs.sorted(by: { $0.raw < $1.raw }) {
            let path = "/v1/user/\(user.raw)/monetary-account/\(accountID.raw)/payment"
            let stream = "bunq-payments-account-\(accountID.raw)"
            var paymentCursor: Bunq.Pagination.Cursor?
            var paymentIDs = Set<Bunq.Payment.ID>()
            var seen = Set<String>()
            var pageNumber = 0
            repeat {
                guard pageNumber < maximumPages else { throw SourceFailure.incompletePagination }
                let response = try await client.user(user).account(accountID).payments.list(
                    cursor: paymentCursor
                )
                let captured = try await capture.take(expectedPath: path)
                try acceptUniqueQuery(captured, into: &seen)
                pageNumber += 1
                for payment in response.items {
                    guard payment.monetary_account_id == accountID,
                          paymentIDs.insert(payment.id).inserted
                    else { throw SourceFailure.duplicateRecord }
                }
                try await archive.append(
                    stream: stream, scope: String(accountID.raw),
                    page: pageNumber, captured: captured, itemCount: response.items.count
                )
                paymentCursor = response.pagination.older
            } while paymentCursor != nil
            try await archive.finishStream(
                name: stream, scope: String(accountID.raw), itemCount: paymentIDs.count
            )
        }
        try await archive.complete()
    }

    /// Preserve all page responses and full Idefix transaction details.
    /// PAY. is a payment processor: settlements/clearings are not bank movements.
    public static func paynl(
        gms: PayNL.GMS.Client,
        idefix: PayNL.Idefix.Client,
        capture: ReadCapture,
        archive: SourceArchive,
        sink: (any PayNLProgressSink)? = nil
    ) async throws {
        let clearingPath = "/v2/clearings"
        var clearingIDs = Set<PayNL.GMS.Clearing.ID>()
        var clearingTotal: Int?
        var clearingPages: Int?
        var seen = Set<String>()
        var index = 1
        while true {
            guard index <= maximumPages else { throw SourceFailure.incompletePagination }
            let result = try await gms.clearings.list(page: try PayNL.PageNumber(index))
            let captured = try await capture.take(expectedPath: clearingPath)
            try acceptUniqueQuery(captured, into: &seen)
            try consistentTotal(result.total, baseline: &clearingTotal)
            for clearing in result.items {
                guard clearingIDs.insert(clearing.id).inserted else {
                    throw SourceFailure.duplicateRecord
                }
            }
            try await archive.append(
                stream: "paynl-clearings", scope: "all", page: index,
                captured: captured, itemCount: result.items.count
            )
            let pages = max(result.pages, 1)
            await sink?.emit(.progressed(
                stage: .clearings, completed: index, total: pages, identityMismatches: 0
            ))
            try consistentPages(pages, baseline: &clearingPages)
            guard index < pages else { break }
            index += 1
        }
        try matchTotal(clearingTotal, count: clearingIDs.count)
        try await archive.finishStream(
            name: "paynl-clearings", scope: "all", itemCount: clearingIDs.count
        )

        var clearingDetailPage = 0
        for id in clearingIDs.sorted(by: { $0.raw < $1.raw }) {
            let detail = try await gms.clearings.get(id)
            guard detail.id == id else { throw SourceFailure.invalidCapture }
            let captured = try await capture.take(expectedPath: "/v2/clearings/\(id.raw)")
            clearingDetailPage += 1
            try await archive.append(
                stream: "paynl-clearing-details", scope: "all", page: clearingDetailPage,
                captured: captured, itemCount: 1
            )
            await sink?.emit(.progressed(
                stage: .clearing_details, completed: clearingDetailPage,
                total: clearingIDs.count, identityMismatches: 0
            ))
        }
        if clearingDetailPage > 0 {
            try await archive.finishStream(
                name: "paynl-clearing-details", scope: "all", itemCount: clearingDetailPage
            )
        }

        var completedClearingLines = 0
        for id in clearingIDs.sorted(by: { $0.raw < $1.raw }) {
            let path = "/v2/clearings/\(id.raw)/lines"
            let stream = "paynl-clearing-lines-\(String(SourceArchive.sha256(Data(id.raw.utf8)).prefix(20)))"
            var lineTotal: Int?
            var uniqueLines = Set<String>()
            var seenLinePages = Set<String>()
            var expectedLinePages: Int?
            var pageNumber = 1
            while true {
                guard pageNumber <= maximumPages else {
                    throw SourceFailure.incompletePagination
                }
                let result = try await gms.clearings.lines(
                    for: id, page: try PayNL.PageNumber(pageNumber)
                )
                let captured = try await capture.take(expectedPath: path)
                try acceptUniqueQuery(captured, into: &seenLinePages)
                try consistentTotal(result.total, baseline: &lineTotal)
                for line in result.items {
                    guard uniqueLines.insert(line.code).inserted else {
                        throw SourceFailure.duplicateRecord
                    }
                }
                try await archive.append(
                    stream: stream, scope: id.raw, page: pageNumber,
                    captured: captured, itemCount: result.items.count
                )
                let pages = max(result.pages, 1)
                try consistentPages(pages, baseline: &expectedLinePages)
                guard pageNumber < pages else { break }
                pageNumber += 1
            }
            try matchTotal(lineTotal, count: uniqueLines.count)
            try await archive.finishStream(
                name: stream, scope: id.raw, itemCount: uniqueLines.count
            )
            completedClearingLines += 1
            await sink?.emit(.progressed(
                stage: .clearing_lines, completed: completedClearingLines,
                total: clearingIDs.count, identityMismatches: 0
            ))
        }

        var settlements = Set<PayNL.GMS.Settlement.Code>()
        var settlementTotal: Int?
        var settlementPage = 1
        var expectedSettlementPages: Int?
        var seenSettlements = Set<String>()
        while true {
            guard settlementPage <= maximumPages else {
                throw SourceFailure.incompletePagination
            }
            let result = try await gms.settlements.list(
                page: try PayNL.PageNumber(settlementPage)
            )
            let captured = try await capture.take(expectedPath: "/v2/clearings/settlements")
            try acceptUniqueQuery(captured, into: &seenSettlements)
            try consistentTotal(result.total, baseline: &settlementTotal)
            for item in result.items {
                guard settlements.insert(item.code).inserted else {
                    throw SourceFailure.duplicateRecord
                }
            }
            try await archive.append(
                stream: "paynl-settlements", scope: "all", page: settlementPage,
                captured: captured, itemCount: result.items.count
            )
            let pages = max(result.pages, 1)
            await sink?.emit(.progressed(
                stage: .settlements, completed: settlementPage,
                total: pages, identityMismatches: 0
            ))
            try consistentPages(pages, baseline: &expectedSettlementPages)
            guard settlementPage < pages else { break }
            settlementPage += 1
        }
        try matchTotal(settlementTotal, count: settlements.count)
        try await archive.finishStream(
            name: "paynl-settlements", scope: "all", itemCount: settlements.count
        )

        let limit = PayNL.PageLimit.standard
        var transactionIDs = Set<PayNL.Idefix.Transaction.ID>()
        var transactionSummaries: [PayNL.Idefix.Transaction.ID: PayNL.Idefix.Summary] = [:]
        var orderIDCounts: [String: Int] = [:]
        var reportedTotal: Int?
        var transactionPage = 1
        var expectedTransactionPages: Int?
        var seenTransactions = Set<String>()
        while true {
            guard transactionPage <= maximumPages else {
                throw SourceFailure.incompletePagination
            }
            let result = try await idefix.transactions.list(
                page: try PayNL.PageNumber(transactionPage), limit: limit
            )
            let captured = try await capture.take(expectedPath: "/v2/transactions")
            try acceptUniqueQuery(captured, into: &seenTransactions)
            try consistentTotal(result.total, baseline: &reportedTotal)
            guard result.count == result.transactions.count else {
                throw SourceFailure.incompletePagination
            }
            for item in result.transactions {
                guard transactionIDs.insert(item.id).inserted else {
                    throw SourceFailure.duplicateRecord
                }
                transactionSummaries[item.id] = item
                if let orderID = item.orderId, !orderID.isEmpty {
                    orderIDCounts[orderID, default: 0] += 1
                }
            }
            try await archive.append(
                stream: "paynl-transactions", scope: "all", page: transactionPage,
                captured: captured, itemCount: result.transactions.count
            )
            let inferredPages = max(1, (result.total + limit.raw - 1) / limit.raw)
            let pages = max(result.pages ?? inferredPages, 1)
            await sink?.emit(.progressed(
                stage: .transactions, completed: transactionPage,
                total: pages, identityMismatches: 0
            ))
            guard pages == inferredPages else { throw SourceFailure.incompletePagination }
            try consistentPages(pages, baseline: &expectedTransactionPages)
            guard transactionPage < pages else { break }
            transactionPage += 1
        }
        try matchTotal(reportedTotal, count: transactionIDs.count)
        try await archive.finishStream(
            name: "paynl-transactions", scope: "all", itemCount: transactionIDs.count
        )

        // PAY. documents both EX codes and order IDs as transaction-info locators.
        // Prefer a unique order ID for uncached details; resume existing pages
        // with their original locator so archived bytes are replayed verbatim.
        var detailPage = 0
        var detailMismatches = 0
        await sink?.emit(.progressed(
            stage: .transaction_details, completed: 0,
            total: transactionIDs.count, identityMismatches: 0
        ))
        for id in transactionIDs.sorted(by: { $0.raw < $1.raw }) {
            guard let summary = transactionSummaries[id] else {
                throw SourceFailure.invalidArchive
            }
            let stream = "paynl-transaction-details"
            let nextPage = detailPage + 1
            let idPath = "/v2/transactions/\(id.raw)"
            let uniqueOrderID = summary.orderId.flatMap { value -> String? in
                guard !value.isEmpty, orderIDCounts[value] == 1 else { return nil }
                return value
            }
            let locator: PayNL.Idefix.Transaction.ID
            if let existing = await archive.archivedPage(stream: stream, page: nextPage) {
                guard existing.query == nil else { throw SourceFailure.invalidArchive }
                if existing.path == idPath {
                    locator = id
                } else if let uniqueOrderID,
                          existing.path == "/v2/transactions/\(uniqueOrderID)" {
                    locator = try PayNL.Idefix.Transaction.ID(uniqueOrderID)
                } else {
                    throw SourceFailure.invalidArchive
                }
            } else if let uniqueOrderID {
                // The SDK's path argument accepts the PAY. order ID as well as
                // an EX code; the returned identity is still checked as an EX ID.
                locator = try PayNL.Idefix.Transaction.ID(uniqueOrderID)
            } else {
                locator = id
            }
            let detail = try await idefix.transactions.get(locator)
            let captured = try await capture.take(
                expectedPath: "/v2/transactions/\(locator.raw)"
            )
            // Do not equate distinct EX codes merely because their order IDs match.
            // Preserve every successful raw read, including unexpected provider
            // identities, and mark it unresolved rather than misattributing it.
            let orderMismatch = summary.orderId.map { $0 != detail.orderId } ?? false
            let mismatch: SourceDetailMismatch?
            if detail.id != id || orderMismatch {
                mismatch = SourceDetailMismatch(
                    expectedID: id.raw, observedID: detail.id.raw,
                    expectedOrderID: summary.orderId, observedOrderID: detail.orderId,
                    observedIDInBrowse: transactionIDs.contains(detail.id)
                )
            } else {
                mismatch = nil
            }
            detailPage = nextPage
            try await archive.append(
                stream: "paynl-transaction-details", scope: "all", page: detailPage,
                captured: captured, itemCount: 1, detailMismatch: mismatch
            )
            if mismatch != nil { detailMismatches += 1 }
            await sink?.emit(.progressed(
                stage: .transaction_details, completed: detailPage,
                total: transactionIDs.count, identityMismatches: detailMismatches
            ))
        }
        // An empty detail collection still has a documented zero-record stream.
        if detailPage > 0 {
            try await archive.finishStream(
                name: "paynl-transaction-details", scope: "all", itemCount: detailPage
            )
        }
        try await archive.complete()
    }

    private static func acceptUniqueQuery(
        _ captured: CapturedRead, into seen: inout Set<String>
    ) throws {
        let key = captured.path + "?" + (captured.query ?? "")
        guard seen.insert(key).inserted else { throw SourceFailure.incompletePagination }
    }

    private static func consistentPages(_ current: Int, baseline: inout Int?) throws {
        guard current > 0, current <= maximumPages else {
            throw SourceFailure.incompletePagination
        }
        if let baseline, baseline != current { throw SourceFailure.incompletePagination }
        baseline = current
    }

    private static func consistentTotal(_ current: Int?, baseline: inout Int?) throws {
        if let current {
            if let baseline, baseline != current { throw SourceFailure.incompletePagination }
            baseline = current
        }
    }

    private static func consistentTotal(_ current: Int, baseline: inout Int?) throws {
        try consistentTotal(Optional(current), baseline: &baseline)
    }

    private static func matchTotal(_ expected: Int?, count: Int) throws {
        guard expected == nil || expected == count else {
            throw SourceFailure.incompletePagination
        }
    }
}
