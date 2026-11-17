import Foundation

/// What a trainer shows their students: name, photo and CREF (the professional registration). Written by the trainer, readable by their own
/// linked students — never by anyone else. Nothing private about the trainer lives here.
public struct TrainerProfile: Syncable, Equatable {
    /// The trainer's account id.
    public var id: UserID
    public var displayName: String
    /// Normalised `NNNNNN-G/UF`; `nil` until the trainer fills it in.
    public var cref: String?
    /// A downsized JPEG.
    public var photo: Data?
    public var meta: SyncMetadata

    public init(id: UserID, displayName: String, cref: String? = nil, photo: Data? = nil, meta: SyncMetadata) {
        self.id = id
        self.displayName = displayName
        self.cref = cref
        self.photo = photo
        self.meta = meta
    }

    public static let maxPhotoBytes = 300_000

    /// "CREF 012345-G/AL" — how the registration is printed on the student's screen.
    public var crefDisplay: String? { cref.map { "CREF \($0)" } }

    public func validated() throws -> TrainerProfile {
        var clean = self
        clean.displayName = displayName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.displayName.isEmpty, clean.displayName.count <= 120 else { throw DomainError.validation("The name must have 1 to 120 characters") }
        if let cref {
            guard let normal = BrazilianCredentialRecognizer.normalizedCREF(cref) else { throw DomainError.validation("That CREF isn't valid") }
            clean.cref = normal
        }
        if let photo, photo.count > Self.maxPhotoBytes { throw DomainError.validation("The photo is too large") }
        return clean
    }
}

public protocol TrainerProfileRepository: Sendable {
    @discardableResult func save(_ profile: TrainerProfile) async throws -> TrainerProfile
    func profile(trainerID: UserID) async throws -> TrainerProfile?
    func observeProfile(trainerID: UserID) -> AsyncStream<TrainerProfile?>
}

/// The trainer's own edits to what students see. Writes only when something actually changed, so signing in on a second device doesn't
/// bump the version (and re-sync the photo) every time.
public struct PublishTrainerProfileUseCase: Sendable {
    public let repository: any TrainerProfileRepository
    public let deviceID: String
    public let now: @Sendable () -> Date

    public init(repository: any TrainerProfileRepository, deviceID: String = "", now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.deviceID = deviceID
        self.now = now
    }

    @discardableResult
    public func execute(trainerID: UserID, displayName: String, edit: (inout TrainerProfile) -> Void = { _ in }) async throws -> TrainerProfile {
        let existing = try await repository.profile(trainerID: trainerID)
        var updated = existing ?? TrainerProfile(id: trainerID, displayName: displayName, meta: SyncMetadata(updatedAt: now(), lastWriterDeviceID: deviceID))
        updated.displayName = displayName
        edit(&updated)
        let valid = try updated.validated()
        if let existing, existing.displayName == valid.displayName, existing.cref == valid.cref, existing.photo == valid.photo, !existing.meta.isDeleted { return existing }
        return try await repository.save(valid)
    }
}
