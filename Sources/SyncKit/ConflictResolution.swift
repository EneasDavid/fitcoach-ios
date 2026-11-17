import Foundation

public enum ConflictPolicy: Equatable, Sendable {
    /// The device is authoritative (e.g. a student's own workout logs).
    case clientWins
    /// The server is authoritative; the local edit is dropped.
    case serverWins
    /// Compare the edit's client time with the server's last-write time. Subject to clock skew:
    /// use only where a rare wrong pick is tolerable (trainer on two devices).
    case lastWriteWins
    /// Keep the local edit but let the server keep ownership of the listed fields
    /// (e.g. `role`, `trainerID` on a profile — only Cloud Functions may change them).
    case mergePreferringRemote(fields: Set<String>)
}

public enum ConflictDecision: Equatable, Sendable {
    /// Retry the local mutation on top of the server's current revision.
    case keepLocal
    /// Discard the local mutation; the inbound listener brings the server copy down.
    case keepRemote
    /// Retry with this payload instead.
    case merged([String: JSONValue])
}

public protocol ConflictResolving: Sendable {
    func resolve(local: Mutation, remote: RemoteDocument) -> ConflictDecision
}

/// Chooses a policy per collection (by leaf name, e.g. `workoutLogs`).
public struct PolicyConflictResolver: ConflictResolving {
    public var policies: [String: ConflictPolicy]
    public var defaultPolicy: ConflictPolicy

    public init(policies: [String: ConflictPolicy], defaultPolicy: ConflictPolicy = .lastWriteWins) {
        self.policies = policies
        self.defaultPolicy = defaultPolicy
    }

    public func resolve(local: Mutation, remote: RemoteDocument) -> ConflictDecision {
        switch policies[local.path.leafCollection] ?? defaultPolicy {
        case .clientWins:
            return .keepLocal
        case .serverWins:
            return .keepRemote
        case .lastWriteWins:
            if let serverTime = remote.updatedAt, serverTime > local.editedAt { return .keepRemote }
            return .keepLocal
        case .mergePreferringRemote(let remoteOwned):
            guard local.kind != .delete else { return .keepLocal }
            var merged = local.payload
            for field in remoteOwned {
                if let value = remote.fields[field] {
                    if local.kind == .upsert { merged[field] = value } else { merged[field] = nil }
                }
            }
            return .merged(merged)
        }
    }
}
