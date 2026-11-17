import Foundation
import Testing
import Domain
import SecurityKit
import SyncKit
@testable import DataKit

@Suite("Feed, activity and integration repositories")
struct FeedRepositoryTests {
    func offlineStore<E: Syncable>(_ descriptor: EntityDescriptor<E>) -> (OfflineFirstStore<E>, MutationQueue) {
        let clock = TestClock()
        let cipher = FieldCipher(keys: KeychainKeyProvider(store: InMemorySecureStore()), purpose: "records")
        let queue = MutationQueue(store: InMemoryMutationStore(), now: { clock.now() })
        let store = OfflineFirstStore(descriptor: descriptor, store: SealedRecordStore(inner: InMemoryRecordStore(), cipher: cipher),
                                      queue: queue, trigger: DeferredSyncTrigger(), deviceID: "iphone", now: { clock.now() })
        return (store, queue)
    }

    func post(_ id: String, at offset: TimeInterval = 0) -> ActivityPost {
        ActivityPost(id: PostID(id), studentID: "s1", kind: .workout, createdAt: DFx.t0.addingTimeInterval(offset), title: "Workout \(id)",
                     tracks: [PostTrack(title: "Song", artist: "Artist", plays: 2)], meta: DFx.meta())
    }

    func activity(_ id: String, at offset: TimeInterval = 0) -> ExternalActivity {
        ExternalActivity(studentID: "s1", externalID: id, sportType: "Run", name: "Run \(id)", startedAt: DFx.t0.addingTimeInterval(offset),
                         movingSeconds: 1_800, elapsedSeconds: 1_900, distanceMeters: 5_000, meta: DFx.meta())
    }

    @Test("Paths follow the Firestore layout the rules protect")
    func paths() {
        #expect(EntityDescriptor<ActivityPost>.post.path(post("p1")).description == "students/s1/posts/p1")
        #expect(EntityDescriptor<ExternalActivity>.externalActivity.path(activity("99")).description == "students/s1/externalActivities/strava-99")
        let link = IntegrationLink(studentID: "s1", provider: .strava, isConnected: true, meta: DFx.meta())
        #expect(EntityDescriptor<IntegrationLink>.integrationLink.path(link).description == "students/s1/integrations/strava")
        let prefs = SharingPreferences(studentID: "s1", meta: DFx.meta())
        #expect(EntityDescriptor<SharingPreferences>.sharingPreferences.path(prefs).description == "students/s1/sharing/preferences")
    }

    @Test("Posts are newest first, saved offline-first, and a re-saved post stays one post")
    func posts() async throws {
        let (store, queue) = offlineStore(.post)
        let repo = PostRepositoryImpl(store: store)
        _ = try await repo.save(post("old", at: 0))
        _ = try await repo.save(post("new", at: 3_600))
        _ = try await repo.save(post("new", at: 3_600))
        #expect(try await repo.posts(studentID: "s1").map(\.id.rawValue) == ["new", "old"])
        #expect(try await queue.counts().pending == 2)            // coalesced: one mutation per document
    }

    @Test("Strava activities arrive from the server (applyRemote) and the repository only reads them")
    func externalActivities() async throws {
        let (store, queue) = offlineStore(.externalActivity)
        let repo = ExternalActivityRepositoryImpl(store: store)
        for (id, offset) in [("1", 0.0), ("2", 7_200.0)] {
            let fields = try SyncCoding.fields(activity(id, at: offset))
            #expect(try await store.applyRemote(RemoteDocument(fields: fields, version: 1)) == .applied)
        }
        #expect(try await repo.activities(studentID: "s1", since: nil).map(\.externalID) == ["2", "1"])
        #expect(try await repo.activities(studentID: "s1", since: DFx.t0.addingTimeInterval(3_600)).map(\.externalID) == ["2"])
        #expect(try await queue.counts().isEmpty)               // nothing the rules would reject was ever enqueued
    }

    @Test("Conflicts: the server owns activities and the proof of who is connected; the student owns their own switches")
    func policies() {
        let resolver = PolicyConflictResolver.fitCoach
        func resolve(_ collection: String) -> ConflictDecision {
            let mutation = Mutation(path: DocumentPath(collection: "students/s1/\(collection)", documentID: "x"), kind: .upsert,
                                    payload: ["externalAccountID": .string("999")], createdAt: DFx.t0)
            return resolver.resolve(local: mutation, remote: RemoteDocument(fields: ["externalAccountID": .string("777")], version: 3, updatedAt: DFx.t0))
        }
        #expect(resolve("externalActivities") == .keepRemote)
        #expect(resolve("integrations") == .keepRemote)         // a tampered account id is discarded, the server copy comes back down
        #expect(resolve("posts") == .keepLocal)
        #expect(resolve("sharing") == .keepLocal)
    }

    @Test("Integration link is read-only here: it arrives from the server and nothing is ever queued")
    func integrationLinks() async throws {
        let (store, queue) = offlineStore(.integrationLink)
        let repo = IntegrationLinkRepositoryImpl(store: store)
        let link = IntegrationLink(studentID: "s1", provider: .strava, isConnected: true, externalAccountID: "777", meta: DFx.meta())
        #expect(try await store.applyRemote(RemoteDocument(fields: try SyncCoding.fields(link), version: 1)) == .applied)
        #expect(try await repo.link(provider: .strava, studentID: "s1")?.externalAccountID == "777")
        #expect(try await repo.link(provider: .spotify, studentID: "s1") == nil)
        #expect(try await queue.counts().isEmpty)
    }

    @Test("Sharing preferences default to everything off, persist offline-first, and are observable")
    func sharingPreferences() async throws {
        let (store, queue) = offlineStore(.sharingPreferences)
        let repo = SharingPreferencesRepositoryImpl(store: store, now: { DFx.t0 })
        let initial = try await repo.preferences(studentID: "s1")
        #expect(initial.shareStravaWithTrainer == false && initial.includeMusicInPosts == false)

        var iterator = repo.observePreferences(studentID: "s1").makeAsyncIterator()
        #expect(await iterator.next()?.shareStravaWithTrainer == false)

        var changed = initial
        changed.shareStravaWithTrainer = true
        _ = try await repo.save(changed)
        #expect(await iterator.next()?.shareStravaWithTrainer == true)
        #expect(try await repo.preferences(studentID: "s1").shareStravaWithTrainer == true)
        #expect(try await queue.counts().pending == 1)
    }

    @Test("Contract with the Cloud Function: the exact document it writes decodes into an ExternalActivity")
    func decodesWhatTheFunctionWrites() throws {
        // contract/external-activity.golden.json is asserted byte-for-byte against functions/lib/strava.js `mapActivity`
        // by the node tests, and decoded here — so a renamed field on either side fails a test.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contract/external-activity.golden.json"))
        let activity = try SyncCoding.decode(ExternalActivity.self, from: data)

        #expect(activity.id == ExternalActivityID("strava-9876543210"))
        #expect(activity.source == .strava && activity.externalID == "9876543210")
        #expect(activity.studentID == "student-1" && activity.sportType == "Run" && activity.name == "Morning Run")
        #expect(activity.startedAt == Date(timeIntervalSince1970: 1_705_303_800))
        #expect(activity.movingSeconds == 1_805 && activity.elapsedSeconds == 1_900)
        #expect(activity.distanceMeters == 5_234.6 && activity.elevationGainMeters == 41 && activity.averageHeartRate == 152)
        #expect(activity.meta.version == 1 && activity.meta.lastWriterDeviceID == "cloud-function" && !activity.meta.isDeleted)
    }

    func sharedPhoto(_ id: String, at offset: TimeInterval = 0, bytes: [UInt8] = [1, 2, 3]) -> SharedPhoto {
        SharedPhoto(id: PostID(id), studentID: "s1", logID: "log-1", takenAt: DFx.t0.addingTimeInterval(offset), caption: "Treino \(id)",
                    photo: Data(bytes), meta: DFx.meta())
    }

    @Test("Shared photos live where the trainer is allowed to read them, apart from the private cards")
    func sharedPhotoPath() {
        #expect(EntityDescriptor<SharedPhoto>.sharedPhoto.path(sharedPhoto("p1")).description == "students/s1/sharedPhotos/p1")
        #expect(EntityDescriptor<ActivityPost>.post.path(post("p1")).description == "students/s1/posts/p1")
        #expect(PolicyConflictResolver.fitCoach.policies["sharedPhotos"] == .clientWins)
    }

    @Test("Shared photos: newest first, one per card, and removing one drops the bytes and leaves a tombstone")
    func sharedPhotos() async throws {
        let (store, queue) = offlineStore(.sharedPhoto)
        let repo = SharedPhotoRepositoryImpl(store: store)
        _ = try await repo.save(sharedPhoto("old", at: 0))
        _ = try await repo.save(sharedPhoto("new", at: 3_600))
        _ = try await repo.save(sharedPhoto("new", at: 3_600, bytes: [9, 9]))               // the same card again is still one photo
        #expect(try await repo.photos(studentID: "s1").map(\.id.rawValue) == ["new", "old"])
        #expect(try await repo.photos(studentID: "s1").first?.photo == Data([9, 9]))
        #expect(try await repo.photos(studentID: "s2").isEmpty)

        try await repo.remove(id: "new", studentID: "s1")
        #expect(try await repo.photos(studentID: "s1").map(\.id.rawValue) == ["old"])
        let tombstone = try await store.get(id: "new")
        #expect(tombstone?.meta.isDeleted == true && tombstone?.photo.isEmpty == true)         // the picture is gone, the removal can sync
        try await repo.remove(id: "never-existed", studentID: "s1")                            // removing nothing is not an error
        try await repo.remove(id: "old", studentID: "someone-else")                            // and never touches another student's photo
        #expect(try await repo.photos(studentID: "s1").map(\.id.rawValue) == ["old"])
        #expect(try await queue.counts().pending >= 2)
    }

    @Test("Observing shared photos hides removed ones")
    func observeSharedPhotos() async throws {
        let (store, _) = offlineStore(.sharedPhoto)
        let repo = SharedPhotoRepositoryImpl(store: store)
        _ = try await repo.save(sharedPhoto("a", at: 0))
        var iterator = repo.observePhotos(studentID: "s1").makeAsyncIterator()
        #expect(await iterator.next()?.map(\.id.rawValue) == ["a"])
        try await repo.remove(id: "a", studentID: "s1")
        #expect(await iterator.next()?.isEmpty == true)
    }

    @Test("The trainer profile is one document per trainer, readable by that trainer's students")
    func trainerProfileStore() async throws {
        #expect(EntityDescriptor<TrainerProfile>.trainerProfile.path(TrainerProfile(id: "t1", displayName: "P", meta: DFx.meta())).description == "trainerProfiles/t1")
        #expect(PolicyConflictResolver.fitCoach.policies["trainerProfiles"] == .clientWins)

        let (store, _) = offlineStore(.trainerProfile)
        let repo = TrainerProfileRepositoryImpl(store: store)
        #expect(try await repo.profile(trainerID: "t1") == nil)
        _ = try await repo.save(TrainerProfile(id: "t1", displayName: "Personal Demo", cref: "012345-G/AL", photo: Data([1]), meta: DFx.meta()))
        _ = try await repo.save(TrainerProfile(id: "t2", displayName: "Other", meta: DFx.meta()))
        let mine = try await repo.profile(trainerID: "t1")
        #expect(mine?.displayName == "Personal Demo" && mine?.cref == "012345-G/AL" && mine?.photo == Data([1]))

        var iterator = repo.observeProfile(trainerID: "t1").makeAsyncIterator()
        let first = await iterator.next()
        #expect(first??.id == "t1")                                         // only their own document comes through
    }
}

