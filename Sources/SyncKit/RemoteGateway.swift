import Foundation

/// A server document as the sync engine sees it.
public struct RemoteDocument: Equatable, Sendable {
    public let fields: [String: JSONValue]
    /// Server-owned revision counter (`_rev`), incremented by the gateway on every accepted write.
    public let version: Int
    /// Server timestamp of the last accepted write (`_updatedAt`).
    public let updatedAt: Date?

    public init(fields: [String: JSONValue], version: Int, updatedAt: Date? = nil) {
        self.fields = fields
        self.version = version
        self.updatedAt = updatedAt
    }
}

public struct RemoteApplyResult: Equatable, Sendable {
    /// The document's `_rev` after the write.
    public let version: Int
    /// `true` when the server recognised the mutation id and did not apply it a second time.
    public let alreadyApplied: Bool

    public init(version: Int, alreadyApplied: Bool = false) {
        self.version = version
        self.alreadyApplied = alreadyApplied
    }
}

/// Failure taxonomy the dispatcher reasons about. A gateway maps its SDK's errors onto these.
public enum RemoteError: Error, Equatable, Sendable {
    /// No connectivity. Not the mutation's fault: stop draining, don't consume an attempt.
    case offline
    /// Retry with backoff (unavailable, deadline exceeded, resource exhausted…).
    case transient(retryAfter: TimeInterval?)
    /// The document changed on the server since `baseVersion`.
    case conflict(serverVersion: Int?)
    /// Session expired: pause the whole queue until the user signs in again.
    case unauthenticated
    /// Security rules rejected the write. Retrying cannot help: dead-letter it.
    case permissionDenied
    /// The server rejected the payload as malformed. Dead-letter it.
    case invalid(String)
    case notFound
}

/// Port to the backend. The Firestore implementation lives in the app target; tests use a simulator.
///
/// Contract for `apply` (all in one server-side transaction):
///  1. If the stored document's `_mutationId` equals `mutation.id` → return `alreadyApplied` (idempotent replay).
///  2. If `mutation.baseVersion` is non-nil and ≠ stored `_rev` (0 when absent) → throw `.conflict`.
///  3. Write the payload, set `_rev += 1`, `_mutationId = mutation.id`, `_updatedAt = server time`.
public protocol RemoteGateway: Sendable {
    func apply(_ mutation: Mutation) async throws -> RemoteApplyResult
    func fetch(_ path: DocumentPath) async throws -> RemoteDocument?
}
