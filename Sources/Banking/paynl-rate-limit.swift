import Foundation
import PayNL
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PayNLReadPolicy: Sendable {
    public let minimumInterval: Duration
    public let initialBackoff: Duration
    public let maximumWait: Duration
    public let maximumRetries: Int

    public init(
        minimumInterval: Duration = .seconds(2),
        initialBackoff: Duration = .seconds(5),
        maximumWait: Duration = .seconds(300),
        maximumRetries: Int = 5
    ) throws {
        guard minimumInterval >= .zero,
              initialBackoff >= .zero,
              maximumWait >= .zero,
              (0...8).contains(maximumRetries)
        else { throw SourceFailure.invalidScope }

        self.minimumInterval = minimumInterval
        self.initialBackoff = initialBackoff
        self.maximumWait = maximumWait
        self.maximumRetries = maximumRetries
    }
}

/// Applies shared pacing and bounded HTTP 429 retries to read-only PAY. requests.
/// A successful response is forwarded only once; rejected response bodies are never archived.
public actor PayNLReadGovernor {
    private let transport: PayNL.Transport
    private let policy: PayNLReadPolicy
    private let sink: (any PayNLProgressSink)?
    private let clock = ContinuousClock()
    private var nextAllowed: ContinuousClock.Instant?

    public init(
        transport: PayNL.Transport = .live,
        policy: PayNLReadPolicy,
        sink: (any PayNLProgressSink)? = nil
    ) {
        self.transport = transport
        self.policy = policy
        self.sink = sink
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.httpMethod == "GET" else {
            return try await transport.send(request)
        }

        var retries = 0
        while true {
            try await reserveRequestSlot()
            let (body, response) = try await transport.send(request)
            guard response.statusCode == 429 else { return (body, response) }
            guard retries < policy.maximumRetries else {
                await report429(retry: retries, wait: nil, stopping: true)
                return (body, response)
            }

            let delay = Self.retryAfter(response) ?? policy.initialBackoff * (1 << retries)
            guard delay <= policy.maximumWait else {
                await report429(retry: retries, wait: delay, stopping: true)
                return (body, response)
            }

            let now = clock.now
            let retryAt = now.advanced(by: delay)
            nextAllowed = max(nextAllowed ?? now, retryAt)
            retries += 1
            await report429(retry: retries, wait: delay, stopping: false)
        }
    }

    private func reserveRequestSlot() async throws {
        let now = clock.now
        let slot = max(now, nextAllowed ?? now)
        nextAllowed = slot.advanced(by: policy.minimumInterval)
        if slot > now { try await clock.sleep(until: slot) }
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        if let seconds = Int64(raw), seconds >= 0 {
            return .seconds(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: raw) else { return nil }
        return .milliseconds(Int64(max(0, (date.timeIntervalSinceNow * 1000).rounded(.up))))
    }

    private func report429(retry: Int, wait: Duration?, stopping: Bool) async {
        if let sink {
            await sink.emit(.rate_limited(
                retry: retry, maximumRetries: policy.maximumRetries,
                wait: wait, stopping: stopping
            ))
        } else {
            let message = stopping
                ? "PAY. HTTP 429: retry limit or maximum wait reached; stopping safely"
                : "PAY. HTTP 429: retry \(retry)/\(policy.maximumRetries) after \(wait ?? .zero)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
}
