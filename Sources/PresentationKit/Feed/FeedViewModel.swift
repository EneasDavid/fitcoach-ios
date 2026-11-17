import Domain
import Foundation
import Observation

/// The student's feed: automatic cards (workout, PR with the song that was playing, playlist of the day, Strava activity).
@MainActor
@Observable
public final class FeedViewModel {
    public private(set) var posts: [ActivityPost] = []
    public private(set) var isLoaded = false

    public private(set) var errorMessage: String?

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let repository: any PostRepository
    /// Shrinks a picked photo to something a feed card (and a Firestore document) can carry; `nil` = unusable image.
    @ObservationIgnored private let processPhoto: (Data) -> Data?

    /// Mirrors a photo to where the student's trainer can see it. `nil` keeps photos on the card only.
    @ObservationIgnored private let attach: AttachPostPhotoUseCase?

    public init(studentID: UserID, posts: any PostRepository, photos: (any SharedPhotoRepository)? = nil,
                processPhoto: @escaping (Data) -> Data? = { $0 }) {
        self.studentID = studentID
        self.repository = posts
        self.attach = photos.map { AttachPostPhotoUseCase(posts: posts, photos: $0) }
        self.processPhoto = processPhoto
    }

    /// Attaches (or, with `nil`, removes) a photo on one of the student's own cards.
    public func setPhoto(_ data: Data?, on post: ActivityPost) async {
        var processed: Data?
        if let data {
            guard let usable = processPhoto(data) else { errorMessage = String(localized: "Couldn't use that photo."); return }
            processed = usable
        }
        do {
            if let attach {
                try await attach.execute(post: post, photo: processed)
            } else {
                var updated = post
                updated.photo = processed
                _ = try await repository.save(updated)
            }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn't save the photo.")
        }
    }

    public func dismissError() { errorMessage = nil }

    public var isEmpty: Bool { isLoaded && posts.isEmpty }

    public func run() async {
        for await items in repository.observePosts(studentID: studentID) {
            posts = items
            isLoaded = true
        }
    }
}

public extension PostKind {
    var systemImage: String {
        switch self {
        case .personalRecord: return "trophy.fill"
        case .workout: return "figure.strengthtraining.traditional"
        case .playlistOfTheDay: return "headphones"
        case .externalActivity: return "figure.run"
        }
    }

    var displayName: String {
        switch self {
        case .personalRecord: return String(localized: "Personal record")
        case .workout: return String(localized: "Workout")
        case .playlistOfTheDay: return String(localized: "Playlist of the day")
        case .externalActivity: return String(localized: "Activity")
        }
    }
}
