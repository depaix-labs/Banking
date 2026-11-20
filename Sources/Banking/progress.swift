/// Structured PAY. acquisition events independent of terminal presentation.
/// Never contains record identifiers, response bodies, or credentials.
public enum PayNLProgressEvent: Sendable {
    public enum Stage: String, Sendable {
        case clearings
        case clearing_details
        case clearing_lines
        case settlements
        case transactions
        case transaction_details
    }

    case progressed(
        stage: Stage,
        completed: Int,
        total: Int?,
        identityMismatches: Int
    )
    case rate_limited(
        retry: Int,
        maximumRetries: Int,
        wait: Duration?,
        stopping: Bool
    )
}

public protocol PayNLProgressSink: Sendable {
    func emit(_ event: PayNLProgressEvent) async
}
