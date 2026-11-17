import Foundation

/// A photo the student attached to one of their cards — the only part of a card the trainer can see.
///
/// Cards themselves stay private to the student (they can carry the songs that were playing). A photo is mirrored into its own
/// document, readable by the student's linked trainer, so the trainer sees the pictures without ever reaching the music.
public struct SharedPhoto: Syncable, Equatable {
    /// The id of the card the photo belongs to: one photo per card.
    public var id: PostID
    public var studentID: UserID
    /// The workout the card was made from, when there is one — so the trainer can show it next to that day's sets.
    public var logID: LogID?
    public var takenAt: Date
    /// The card's title ("Treino C · Pernas"), so a photo is never anonymous.
    public var caption: String
    /// Downsized JPEG. Empty once the student removed it.
    public var photo: Data
    public var meta: SyncMetadata

    public init(id: PostID, studentID: UserID, logID: LogID? = nil, takenAt: Date, caption: String, photo: Data, meta: SyncMetadata) {
        self.id = id
        self.studentID = studentID
        self.logID = logID
        self.takenAt = takenAt
        self.caption = caption
        self.photo = photo
        self.meta = meta
    }
}

public protocol SharedPhotoRepository: Sendable {
    @discardableResult func save(_ photo: SharedPhoto) async throws -> SharedPhoto
    /// Soft-deletes (a tombstone every device and the trainer see) and drops the picture bytes.
    func remove(id: PostID, studentID: UserID) async throws
    /// Newest first, removed ones excluded.
    func photos(studentID: UserID) async throws -> [SharedPhoto]
    func observePhotos(studentID: UserID) -> AsyncStream<[SharedPhoto]>
}

/// Attaches (or removes) the photo on a card **and** mirrors it where the trainer can see it. One place decides that the two always
/// move together, so a photo can never be on the card but missing for the trainer (or the other way round).
public struct AttachPostPhotoUseCase: Sendable {
    public let posts: any PostRepository
    public let photos: any SharedPhotoRepository
    public let now: @Sendable () -> Date

    public init(posts: any PostRepository, photos: any SharedPhotoRepository, now: @escaping @Sendable () -> Date = { Date() }) {
        self.posts = posts
        self.photos = photos
        self.now = now
    }

    @discardableResult
    public func execute(post: ActivityPost, photo: Data?) async throws -> ActivityPost {
        var updated = post
        updated.photo = photo
        let saved = try await posts.save(updated)
        if let photo {
            try await photos.save(SharedPhoto(id: post.id, studentID: post.studentID, logID: post.sourceLogID, takenAt: now(), caption: post.title,
                                              photo: photo, meta: SyncMetadata(updatedAt: now(), lastWriterDeviceID: "")))
        } else {
            try await photos.remove(id: post.id, studentID: post.studentID)
        }
        return saved
    }
}
