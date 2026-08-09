import Foundation

/// Prevents concurrent token refreshes for the same instance.
///
/// When multiple callers need a refresh simultaneously (e.g. parallel API calls),
/// only one actually performs the network request. Others await and share the
/// result. Uses `@MainActor` for atomic check-and-insert without locks.
@MainActor
final class OAuthRefreshSingleFlight<Token: Sendable> {

    private var inFlight: [String: Task<Token, Error>] = [:]

    init() {}

    /// Whether a refresh is currently running for `instanceId`.
    func hasInFlight(_ instanceId: String) -> Bool {
        inFlight[instanceId] != nil
    }

    /// Run `perform` under single-flight deduplication for `instanceId`.
    ///
    /// - If a refresh is already in progress, awaits and reuses its result.
    /// - Otherwise starts a new task, tracks it, and clears the slot when done.
    func run(instanceId: String, perform: @escaping () async throws -> Token) async throws -> Token {
        if let existing = inFlight[instanceId] {
            return try await existing.value
        }

        let task = Task<Token, Error> { try await perform() }
        inFlight[instanceId] = task
        defer { inFlight[instanceId] = nil }
        return try await task.value
    }
}
