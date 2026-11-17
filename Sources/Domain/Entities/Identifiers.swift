import Foundation

/// Strongly-typed identifier. The phantom `Tag` makes it a compile error to pass a `PlanID`
/// where a `UserID` is expected, while still serialising as a plain string (Firestore doc ID).
public struct Identifier<Tag>: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static func generate() -> Self { Self(UUID().uuidString.lowercased()) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum UserTag {}
public enum PlanTag {}
public enum TemplateTag {}
public enum BlockTag {}
public enum ExerciseTag {}
public enum LogTag {}
public enum CheckInTag {}
public enum CheckpointTag {}
public enum PostTag {}
public enum ExternalActivityTag {}

public typealias UserID = Identifier<UserTag>
public typealias PlanID = Identifier<PlanTag>
public typealias TemplateID = Identifier<TemplateTag>
public typealias BlockID = Identifier<BlockTag>
public typealias ExerciseID = Identifier<ExerciseTag>
public typealias LogID = Identifier<LogTag>
public typealias CheckInID = Identifier<CheckInTag>
public typealias CheckpointID = Identifier<CheckpointTag>
public typealias PostID = Identifier<PostTag>
public typealias ExternalActivityID = Identifier<ExternalActivityTag>
