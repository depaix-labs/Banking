import Banking
import Foundation
import PayNL
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum RateLimitFixtureFailure: Error {
    case mismatch
}

private actor RateLimitFixture {
    private let statuses: [Int]
    private let retryAfter: String?
    private(set) var requests = 0

    init(_ statuses: [Int], retryAfter: String? = "0") {
        self.statuses = statuses
        self.retryAfter = retryAfter
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, requests < statuses.count else {
            throw RateLimitFixtureFailure.mismatch
        }
        let status = statuses[requests]
        requests += 1
        let headers: [String: String]
        if status == 429, let retryAfter {
            headers = ["Retry-After": retryAfter]
        } else {
            headers = [:]
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ) else { throw RateLimitFixtureFailure.mismatch }
        return (Data("{\"accepted\":true}".utf8), response)
    }
}

func testPayNLReadGovernor() async throws {
    guard let url = URL(string: "https://rest.pay.nl/v2/clearings") else {
        throw RateLimitFixtureFailure.mismatch
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let policy = try PayNLReadPolicy(
        minimumInterval: .zero,
        initialBackoff: .zero,
        maximumWait: .seconds(1),
        maximumRetries: 2
    )

    let recovered = RateLimitFixture([429, 429, 200])
    let recoverGovernor = PayNLReadGovernor(
        transport: PayNL.Transport { request in try await recovered.send(request) },
        policy: policy
    )
    let (payload, response) = try await recoverGovernor.send(request)
    let recoverCalls = await recovered.requests
    guard response.statusCode == 200, recoverCalls == 3,
          payload == Data("{\"accepted\":true}".utf8)
    else { throw RateLimitFixtureFailure.mismatch }

    let exhausted = RateLimitFixture([429, 429, 429])
    let exhaustedGovernor = PayNLReadGovernor(
        transport: PayNL.Transport { request in try await exhausted.send(request) },
        policy: policy
    )
    let (_, lastResponse) = try await exhaustedGovernor.send(request)
    let exhaustedCalls = await exhausted.requests
    guard lastResponse.statusCode == 429, exhaustedCalls == 3 else {
        throw RateLimitFixtureFailure.mismatch
    }

    let headerPolicy = try PayNLReadPolicy(
        minimumInterval: .zero,
        initialBackoff: .seconds(30),
        maximumWait: .seconds(1),
        maximumRetries: 2
    )
    let honorHeader = RateLimitFixture([429, 200], retryAfter: "0")
    let headerGovernor = PayNLReadGovernor(
        transport: PayNL.Transport { request in try await honorHeader.send(request) },
        policy: headerPolicy
    )
    let (_, headerResponse) = try await headerGovernor.send(request)
    let headerCalls = await honorHeader.requests
    guard headerResponse.statusCode == 200, headerCalls == 2 else {
        throw RateLimitFixtureFailure.mismatch
    }

    let excessiveHeader = RateLimitFixture([429], retryAfter: "120")
    let excessiveGovernor = PayNLReadGovernor(
        transport: PayNL.Transport { request in try await excessiveHeader.send(request) },
        policy: headerPolicy
    )
    let (_, excessiveResponse) = try await excessiveGovernor.send(request)
    let excessiveCalls = await excessiveHeader.requests
    guard excessiveResponse.statusCode == 429, excessiveCalls == 1 else {
        throw RateLimitFixtureFailure.mismatch
    }

    let notRead = RateLimitFixture([429])
    let notReadGovernor = PayNLReadGovernor(
        transport: PayNL.Transport { request in try await notRead.send(request) },
        policy: policy
    )
    request.httpMethod = "POST"
    let (_, postResponse) = try await notReadGovernor.send(request)
    let postCalls = await notRead.requests
    guard postResponse.statusCode == 429, postCalls == 1 else {
        throw RateLimitFixtureFailure.mismatch
    }
}
