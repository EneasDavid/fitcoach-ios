import Foundation

public enum UserRole: String, Codable, Sendable, CaseIterable {
    case trainer
    case student
}

public struct UserProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UserID
    public var role: UserRole
    public var displayName: String
    /// Set server-side (Cloud Function) when a student accepts a trainer invitation.
    public var trainerID: UserID?
    public var createdAt: Date

    public init(id: UserID, role: UserRole, displayName: String, trainerID: UserID? = nil, createdAt: Date) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.trainerID = trainerID
        self.createdAt = createdAt
    }
}
