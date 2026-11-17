import Domain
import Observation

/// "Your trainer": the name, photo and CREF the trainer chose to show, kept up to date as they change.
@MainActor
@Observable
public final class StudentTrainerViewModel {
    public private(set) var profile: TrainerProfile?
    public private(set) var isLoaded = false

    @ObservationIgnored private let trainerID: UserID
    @ObservationIgnored private let repository: any TrainerProfileRepository

    public init(trainerID: UserID, repository: any TrainerProfileRepository) {
        self.trainerID = trainerID
        self.repository = repository
    }

    public func run() async {
        for await current in repository.observeProfile(trainerID: trainerID) {
            profile = current
            isLoaded = true
        }
    }

    public var initials: String { Avatar.initials(for: profile?.displayName ?? "") }
}
