import Foundation
import Testing
@testable import Domain

actor InMemoryPostRepository: PostRepository {
    private(set) var stored: [PostID: ActivityPost] = [:]
    func save(_ post: ActivityPost) async throws -> ActivityPost { stored[post.id] = post; return post }
    func posts(studentID: UserID) async throws -> [ActivityPost] { stored.values.sorted { $0.createdAt > $1.createdAt } }
    nonisolated func observePosts(studentID: UserID) -> AsyncStream<[ActivityPost]> { AsyncStream { $0.finish() } }
}

actor InMemorySharedPhotoRepository: SharedPhotoRepository {
    private(set) var stored: [PostID: SharedPhoto] = [:]
    private(set) var removed: [PostID] = []
    var failing = false
    struct Boom: Error {}
    func setFailing(_ value: Bool) { failing = value }
    func save(_ photo: SharedPhoto) async throws -> SharedPhoto {
        if failing { throw Boom() }
        stored[photo.id] = photo
        return photo
    }
    func remove(id: PostID, studentID: UserID) async throws {
        if failing { throw Boom() }
        removed.append(id)
        stored[id] = nil
    }
    func photos(studentID: UserID) async throws -> [SharedPhoto] { stored.values.filter { $0.studentID == studentID }.sorted { $0.takenAt > $1.takenAt } }
    nonisolated func observePhotos(studentID: UserID) -> AsyncStream<[SharedPhoto]> { AsyncStream { $0.finish() } }
}

actor InMemoryTrackPlayRepository: TrackPlayRepository {
    private(set) var stored: [String: TrackPlay] = [:]
    func save(_ plays: [TrackPlay]) async throws { for play in plays { stored[play.id] = play } }
    func plays(studentID: UserID, from: Date, to: Date) async throws -> [TrackPlay] {
        stored.values.filter { $0.startedAt >= from && $0.startedAt <= to }.sorted { $0.startedAt < $1.startedAt }
    }
}

actor FakeMusic: MusicHistoryProviding {
    nonisolated let provider: MusicProvider = .spotify
    private let connected: Bool
    private let result: Result<[TrackPlay], Error>
    private(set) var asked: [Date] = []

    init(connected: Bool = true, result: Result<[TrackPlay], Error>) { self.connected = connected; self.result = result }
    var isConnected: Bool { connected }
    func recentlyPlayed(after date: Date) async throws -> [TrackPlay] { asked.append(date); return try result.get() }
}

struct Boom: Error {}

enum Music {
    static func play(_ id: String, _ title: String, artist: String = "Artist", at start: Date, seconds: Int = 200) -> TrackPlay {
        TrackPlay(provider: .spotify, trackID: id, title: title, artist: artist, startedAt: start, durationSeconds: seconds)
    }
}

@Suite("ListeningAnalytics")
struct ListeningAnalyticsTests {
    let analytics = ListeningAnalytics(calendar: Fx.calendar)
    let t0 = Fx.date(day: 3, hour: 18)

    @Test("A play's id is deterministic, so re-importing the same history can't double-count")
    func idempotentIdentity() {
        let a = Music.play("t1", "Song", at: t0), b = Music.play("t1", "Song", at: t0)
        #expect(a.id == b.id)
        #expect(analytics.topTracks([a, b, a]).first?.plays == 1)
    }

    @Test("Top tracks: most played first, ties by most recent, with artist and count")
    func topTracks() {
        let plays = [
            Music.play("a", "A", artist: "X", at: t0),
            Music.play("b", "B", artist: "Y", at: t0.addingTimeInterval(300)),
            Music.play("a", "A", artist: "X", at: t0.addingTimeInterval(600)),
            Music.play("c", "C", artist: "Z", at: t0.addingTimeInterval(900)),
        ]
        let top = analytics.topTracks(plays)
        #expect(top.map(\.title) == ["A", "C", "B"])        // A ×2, then C and B tied at 1 → C is more recent
        #expect(top[0].plays == 2 && top[0].artist == "X")
        #expect(analytics.topTracks(plays, limit: 1).count == 1)
    }

    @Test("Playlist of the day only holds that calendar day")
    func playlistOfTheDay() {
        let plays = [Music.play("a", "Today", at: t0), Music.play("b", "Yesterday", at: t0.addingTimeInterval(-86_400))]
        #expect(analytics.playlistOfTheDay(plays, day: t0).map(\.title) == ["Today"])
    }

    @Test("Which song was playing: start inclusive, end exclusive, latest start wins on overlap")
    func trackAt() {
        let first = Music.play("a", "A", at: t0, seconds: 200)
        let second = Music.play("b", "B", at: t0.addingTimeInterval(150), seconds: 200)
        #expect(analytics.track(at: t0, in: [first, second])?.title == "A")
        #expect(analytics.track(at: t0.addingTimeInterval(160), in: [first, second])?.title == "B")
        #expect(analytics.track(at: t0.addingTimeInterval(350), in: [first, second]) == nil)
        #expect(analytics.track(at: t0.addingTimeInterval(-1), in: [first]) == nil)
    }

    @Test("The soundtrack includes a song that began before the workout and was still playing")
    func soundtrackOverlap() {
        let plan = Fx.plan()
        var log = Fx.log(plan: plan, template: plan.templates[0], at: t0)
        log.completedAt = t0.addingTimeInterval(3_000)
        let plays = [
            Music.play("early", "Before", at: t0.addingTimeInterval(-100), seconds: 200),     // overlaps the first 100 s
            Music.play("mid", "During", at: t0.addingTimeInterval(1_000)),
            Music.play("late", "After", at: t0.addingTimeInterval(3_100)),
            Music.play("old", "Long gone", at: t0.addingTimeInterval(-7_200)),
        ]
        #expect(Set(analytics.soundtrack(of: log, plays: plays).map(\.title)) == ["Before", "During"])
    }

    @Test("A PR moment finds the song playing when that set was completed")
    func prMoment() throws {
        let plan = Fx.plan(periodization: Fx.threeOneProgram)
        let history = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 3)
        let last = try #require(history.last)
        let when = last.startedAt
        let plays = [Music.play("pr", "Eye of the Tiger", artist: "Survivor", at: when.addingTimeInterval(-60), seconds: 240),
                     Music.play("other", "Elsewhere", at: when.addingTimeInterval(-3_600))]

        let moments = analytics.prMoments(for: last, history: history, plays: plays)
        let moment = try #require(moments.first)
        #expect(moments.count == 1)
        #expect(moment.exercise == Fx.bench)
        #expect(moment.record.weightKg == 85)
        #expect(moment.track?.title == "Eye of the Tiger")
        #expect(moment.achievedAt == when)
    }

    @Test("A heavier deload session is never a record — and so never gets a song attached")
    func deloadIsNotAPR() throws {
        let plan = Fx.plan(periodization: Fx.threeOneProgram)
        let history = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 4, deloadKg: 200)
        let deload = try #require(history.last)
        #expect(deload.periodization?.phase == .deload)
        #expect(analytics.prMoments(for: deload, history: history, plays: [Music.play("t", "T", at: deload.startedAt)]).isEmpty)
    }
}

@Suite("PostComposer")
struct PostComposerTests {
    let composer = PostComposer(analytics: ListeningAnalytics(calendar: Fx.calendar))
    let now = Fx.date(day: 30)

    func prScenario() throws -> (log: WorkoutLog, history: [WorkoutLog], plays: [TrackPlay]) {
        let plan = Fx.plan(periodization: Fx.threeOneProgram)
        let history = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 3)
        let last = try #require(history.last)
        let plays = [Music.play("pr", "Eye of the Tiger", artist: "Survivor", at: last.startedAt.addingTimeInterval(-60), seconds: 240),
                     Music.play("pr", "Eye of the Tiger", artist: "Survivor", at: last.startedAt.addingTimeInterval(-1_000), seconds: 1_100)]
        return (last, history, plays)
    }

    @Test("A record becomes a PR card with the song that was playing")
    func prCard() throws {
        let s = try prScenario()
        let post = composer.workoutPost(log: s.log, history: s.history, plays: s.plays, deviceID: "dev", now: now)
        #expect(post.kind == .personalRecord)
        #expect(post.id == PostID("workout-\(s.log.id)"))
        #expect(post.title.contains("Bench Press"))
        #expect(post.subtitle?.contains("85") == true && post.subtitle?.contains("5") == true)
        #expect(post.tracks.first?.title == "Eye of the Tiger")
        #expect(post.tracks.first?.note != nil)
        #expect(post.sourceLogID == s.log.id)
        #expect(post.stats.contains { $0.label.contains("1RM") })
    }

    @Test("Without a record it is a plain workout card titled by the workout")
    func plainCard() {
        let plan = Fx.plan()
        let log = Fx.log(plan: plan, template: plan.templates[1], at: Fx.date(day: 4), sets: [(60, 8), (60, 8)])
        let post = composer.workoutPost(log: log, history: [log], plays: [], deviceID: "dev", now: now)
        #expect(post.kind == .workout)
        #expect(post.title == "B")
        #expect(post.tracks.isEmpty)
        #expect(post.stats.first { $0.label == String(localized: "Sets") }?.value == "2")
    }

    @Test("Generating the same post twice yields the same id (one post, not two)")
    func stableID() {
        let plan = Fx.plan()
        let log = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 4))
        #expect(composer.workoutPost(log: log, history: [log], plays: [], deviceID: "a", now: now).id
                == composer.workoutPost(log: log, history: [log], plays: [], deviceID: "b", now: now.addingTimeInterval(60)).id)
    }

    @Test("Playlist post: nothing played → no post; otherwise dated id and counted tracks")
    func playlist() throws {
        let day = Fx.date(day: 3, hour: 12)
        #expect(composer.playlistPost(studentID: Fx.student, day: day, plays: [], deviceID: "d", now: now) == nil)
        let plays = [Music.play("a", "A", at: day), Music.play("a", "A", at: day.addingTimeInterval(500)), Music.play("b", "B", at: day.addingTimeInterval(900))]
        let post = try #require(composer.playlistPost(studentID: Fx.student, day: day, plays: plays, deviceID: "d", now: now))
        #expect(post.id == PostID("playlist-2024-01-04"))
        #expect(post.kind == .playlistOfTheDay)
        #expect(post.tracks.map(\.plays) == [2, 1])
    }

    @Test("A Strava activity becomes a card with time and distance")
    func activityCard() {
        let run = ExternalActivity(studentID: Fx.student, externalID: "99", sportType: "Run", name: "Morning run", startedAt: Fx.date(day: 2, hour: 7),
                                   movingSeconds: 1_805, elapsedSeconds: 1_900, distanceMeters: 5_230, meta: Fx.meta())
        let post = composer.activityPost(run, deviceID: "d", now: now)
        #expect(post.kind == .externalActivity)
        #expect(post.id == PostID("activity-strava-99"))
        #expect(post.title == "Morning run")
        #expect(post.stats.contains { $0.value.contains("5.2") || $0.value.contains("5,2") })
    }

    @Test("Share text carries the headline, stats, the song with its count, and the hashtag")
    func shareText() {
        let post = ActivityPost(id: "p", studentID: Fx.student, kind: .personalRecord, createdAt: now, title: "New PR · Bench Press",
                                subtitle: "85 kg × 5", stats: [PostStat(label: "Sets", value: "9")],
                                tracks: [PostTrack(title: "Eye of the Tiger", artist: "Survivor", plays: 3, note: "Playing when you hit it")],
                                meta: Fx.meta())
        let text = ShareTextComposer.text(for: post)
        #expect(text.contains("🏆 New PR · Bench Press"))
        #expect(text.contains("85 kg × 5"))
        #expect(text.contains("Sets 9"))
        #expect(text.contains("🎵 Eye of the Tiger — Survivor ×3 (Playing when you hit it)"))
        #expect(text.hasSuffix("#FitCoach"))
    }
}

@Suite("ActivityReportBuilder")
struct ActivityReportBuilderTests {
    let builder = ActivityReportBuilder(calendar: Fx.calendar)
    let period = DateInterval(start: Fx.date(day: 0, hour: 0), end: Fx.date(day: 7, hour: 0))
    let plan = Fx.plan()

    func run(day: Int, hour: Int = 7, id: String = "r") -> ExternalActivity {
        ExternalActivity(studentID: Fx.student, externalID: "\(id)\(day)", sportType: "Run", name: "Run", startedAt: Fx.date(day: day, hour: hour),
                         movingSeconds: 1_800, elapsedSeconds: 1_800, distanceMeters: 5_000, meta: Fx.meta())
    }

    @Test("Counts completed app workouts in the period, not abandoned or out-of-range ones")
    func appWorkouts() {
        let logs = [Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1)),
                    Fx.log(plan: plan, template: plan.templates[1], at: Fx.date(day: 2), status: .abandoned),
                    Fx.log(plan: plan, template: plan.templates[2], at: Fx.date(day: 12))]
        let report = builder.build(logs: logs, activities: [], period: period, includeExternal: true)
        #expect(report.sessions == 1)
        #expect(report.countBySource == [.fitCoach: 1])
    }

    @Test("Without the student's consent external activities are withheld — and the report says so")
    func consentGate() {
        let report = builder.build(logs: [], activities: [run(day: 1)], period: period, includeExternal: false)
        #expect(report.sessions == 0)
        #expect(report.externalWithheld)
        #expect(builder.build(logs: [], activities: [run(day: 1)], period: period, includeExternal: true).externalWithheld == false)
    }

    @Test("With consent, Strava runs are added up: sessions, active days, time and distance")
    func totals() {
        let logs = [Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 1))]
        let report = builder.build(logs: logs, activities: [run(day: 1, hour: 7), run(day: 3)], period: period, includeExternal: true)
        #expect(report.sessions == 3)
        #expect(report.activeDays == 2)                       // days 1 and 3
        #expect(report.totalDistanceMeters == 10_000)
        #expect(report.countBySource == [.fitCoach: 1, .strava: 2])
        #expect(report.entries.map(\.date) == report.entries.map(\.date).sorted(by: >))
    }

    @Test("A watch's weight-training entry for a session the app already logged is counted once")
    func dedupesStrength() {
        var gym = Fx.log(plan: plan, template: plan.templates[0], at: Fx.date(day: 2, hour: 18))
        gym.completedAt = Fx.date(day: 2, hour: 19)
        let duplicate = ExternalActivity(studentID: Fx.student, externalID: "w1", sportType: "WeightTraining", name: "Lunch Weight Training",
                                         startedAt: Fx.date(day: 2, hour: 18).addingTimeInterval(120), movingSeconds: 3_000, elapsedSeconds: 3_300, meta: Fx.meta())
        let separate = ExternalActivity(studentID: Fx.student, externalID: "w2", sportType: "WeightTraining", name: "Morning lift",
                                        startedAt: Fx.date(day: 4, hour: 7), movingSeconds: 3_000, elapsedSeconds: 3_000, meta: Fx.meta())
        let report = builder.build(logs: [gym], activities: [duplicate, separate], period: period, includeExternal: true)
        #expect(report.sessions == 2)
        #expect(!report.entries.contains { $0.title == "Lunch Weight Training" })
    }

    @Test("Deleted records never appear")
    func tombstones() {
        var gone = run(day: 1)
        gone.meta.deletedAt = Fx.date(day: 2)
        #expect(builder.build(logs: [], activities: [gone], period: period, includeExternal: true).sessions == 0)
    }
}

@Suite("PublishWorkoutPostUseCase")
struct PublishWorkoutPostUseCaseTests {
    let plan = Fx.plan(periodization: Fx.threeOneProgram)
    let now = Fx.date(day: 30)

    func scenario() async throws -> (log: WorkoutLog, logs: InMemoryLogRepository, posts: InMemoryPostRepository, plays: InMemoryTrackPlayRepository) {
        let history = Fx.progressiveLogs(plan: plan, program: Fx.threeOneProgram, weeks: 3)
        let logs = InMemoryLogRepository()
        await logs.seed(history)
        return (try #require(history.last), logs, InMemoryPostRepository(), InMemoryTrackPlayRepository())
    }

    func useCase(_ s: (log: WorkoutLog, logs: InMemoryLogRepository, posts: InMemoryPostRepository, plays: InMemoryTrackPlayRepository),
                 music: FakeMusic?) -> PublishWorkoutPostUseCase {
        PublishWorkoutPostUseCase(logs: s.logs, posts: s.posts, plays: s.plays, music: music,
                                  composer: PostComposer(analytics: ListeningAnalytics(calendar: Fx.calendar)), now: { [now] in now })
    }

    @Test("Connected: history is fetched from before the workout, stored, and the PR card names the song")
    func withMusic() async throws {
        let s = try await scenario()
        let song = Music.play("pr", "Eye of the Tiger", artist: "Survivor", at: s.log.startedAt.addingTimeInterval(-60), seconds: 240)
        let music = FakeMusic(result: .success([song]))

        let post = try await useCase(s, music: music).execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(post.kind == .personalRecord)
        #expect(post.tracks.first?.title == "Eye of the Tiger")
        #expect(await s.plays.stored.count == 1)
        #expect(await music.asked.first == s.log.startedAt.addingTimeInterval(-15 * 60))
        #expect(await s.posts.stored.count == 1)
    }

    @Test("If the music service fails the post is still created, from plays already stored")
    func musicFailureNeverBlocks() async throws {
        let s = try await scenario()
        try await s.plays.save([Music.play("kept", "Stored earlier", at: s.log.startedAt.addingTimeInterval(-60), seconds: 240)])
        let post = try await useCase(s, music: FakeMusic(result: .failure(Boom()))).execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(post.tracks.first?.title == "Stored earlier")
    }

    @Test("Music off, or not connected: the service is never asked")
    func respectsTheSwitch() async throws {
        let s = try await scenario()
        let music = FakeMusic(result: .success([Music.play("x", "X", at: s.log.startedAt)]))
        _ = try await useCase(s, music: music).execute(log: s.log, deviceID: "dev", includeMusic: false)
        #expect(await music.asked.isEmpty)

        let disconnected = FakeMusic(connected: false, result: .success([]))
        _ = try await useCase(s, music: disconnected).execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(await disconnected.asked.isEmpty)
    }

    @Test("Publishing the same workout twice leaves one post")
    func idempotent() async throws {
        let s = try await scenario()
        let uc = useCase(s, music: nil)
        _ = try await uc.execute(log: s.log, deviceID: "dev", includeMusic: true)
        _ = try await uc.execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(await s.posts.stored.count == 1)
    }

    @Test("A photo the student attached survives the card being republished")
    func keepsThePhoto() async throws {
        let s = try await scenario()
        let uc = useCase(s, music: nil)
        var post = try await uc.execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(post.photo == nil)

        post.photo = Data([0xFF, 0xD8, 0xFF])
        _ = try await s.posts.save(post)

        let again = try await uc.execute(log: s.log, deviceID: "dev", includeMusic: true)
        #expect(again.photo == Data([0xFF, 0xD8, 0xFF]))
        #expect(await s.posts.stored[post.id]?.photo == Data([0xFF, 0xD8, 0xFF]))
    }
}

@Suite("SyncListeningUseCase")
struct SyncListeningUseCaseTests {
    let now = Fx.date(day: 3, hour: 20)

    func useCase(_ music: FakeMusic, plays: InMemoryTrackPlayRepository, posts: InMemoryPostRepository, minimum: Int = 3) -> SyncListeningUseCase {
        SyncListeningUseCase(music: music, plays: plays, posts: posts, composer: PostComposer(analytics: ListeningAnalytics(calendar: Fx.calendar)),
                             minimumTracks: minimum, now: { [now] in now })
    }

    func songs(_ count: Int) -> [TrackPlay] {
        (0..<count).map { Music.play("t\($0)", "Song \($0)", at: Fx.date(day: 3, hour: 18).addingTimeInterval(Double($0) * 300)) }
    }

    @Test("Imports from the start of the day and publishes the playlist once there are enough different songs")
    func publishes() async throws {
        let plays = InMemoryTrackPlayRepository(), posts = InMemoryPostRepository()
        let music = FakeMusic(result: .success(songs(4)))
        let post = try await useCase(music, plays: plays, posts: posts).execute(studentID: Fx.student, deviceID: "dev", includeMusic: true)

        #expect(post?.kind == .playlistOfTheDay)
        #expect(post?.id == PostID("playlist-2024-01-04"))
        #expect(post?.tracks.count == 4)
        #expect(await music.asked == [Fx.calendar.startOfDay(for: now)])
        #expect(await plays.stored.count == 4)
        #expect(await posts.stored.count == 1)
    }

    @Test("Syncing again refreshes the same post instead of adding another")
    func idempotent() async throws {
        let plays = InMemoryTrackPlayRepository(), posts = InMemoryPostRepository()
        let uc = useCase(FakeMusic(result: .success(songs(4))), plays: plays, posts: posts)
        _ = try await uc.execute(studentID: Fx.student, deviceID: "dev", includeMusic: true)
        _ = try await uc.execute(studentID: Fx.student, deviceID: "dev", includeMusic: true)
        let storedPosts = await posts.stored.count, storedPlays = await plays.stored.count
        #expect(storedPosts == 1 && storedPlays == 4)
    }

    @Test("Too few songs: plays are kept but no post is made")
    func tooFew() async throws {
        let plays = InMemoryTrackPlayRepository(), posts = InMemoryPostRepository()
        let post = try await useCase(FakeMusic(result: .success(songs(2))), plays: plays, posts: posts)
            .execute(studentID: Fx.student, deviceID: "dev", includeMusic: true)
        let storedPosts = await posts.stored.count, storedPlays = await plays.stored.count
        #expect(post == nil && storedPosts == 0 && storedPlays == 2)
    }

    @Test("Music off or not connected: nothing is requested")
    func optIn() async throws {
        let plays = InMemoryTrackPlayRepository(), posts = InMemoryPostRepository()
        let music = FakeMusic(result: .success(songs(4)))
        let off = try await useCase(music, plays: plays, posts: posts).execute(studentID: Fx.student, deviceID: "d", includeMusic: false)
        let offline = FakeMusic(connected: false, result: .success(songs(4)))
        let disconnected = try await useCase(offline, plays: plays, posts: posts).execute(studentID: Fx.student, deviceID: "d", includeMusic: true)
        let asked = await music.asked.count + offline.asked.count, storedPlays = await plays.stored.count
        #expect(off == nil && disconnected == nil)
        #expect(asked == 0 && storedPlays == 0)
    }

    @Test("When the service fails, what was already stored still produces the playlist")
    func fallsBackToStored() async throws {
        let plays = InMemoryTrackPlayRepository(), posts = InMemoryPostRepository()
        try await plays.save(songs(3))
        let post = try await useCase(FakeMusic(result: .failure(Boom())), plays: plays, posts: posts)
            .execute(studentID: Fx.student, deviceID: "dev", includeMusic: true)
        #expect(post?.tracks.count == 3)
    }
}

@Suite("AttachPostPhotoUseCase")
struct AttachPostPhotoUseCaseTests {
    let when = Fx.date(day: 12, hour: 9)
    let jpeg = Data([0xFF, 0xD8, 0xFF])

    func post(_ id: String = "p1", log: String? = "log-1") -> ActivityPost {
        ActivityPost(id: PostID(id), studentID: "s1", kind: .workout, createdAt: when, title: "Treino C · Pernas",
                     tracks: [PostTrack(title: "Private song", artist: "Someone", plays: 1)], sourceLogID: log.map { LogID($0) },
                     meta: SyncMetadata(updatedAt: when, lastWriterDeviceID: "d"))
    }

    func useCase(_ posts: InMemoryPostRepository, _ photos: InMemorySharedPhotoRepository) -> AttachPostPhotoUseCase {
        AttachPostPhotoUseCase(posts: posts, photos: photos, now: { [when] in when })
    }

    @Test("A photo goes on the card and, with the card's title and workout, to the trainer-visible copy")
    func mirrors() async throws {
        let posts = InMemoryPostRepository(), photos = InMemorySharedPhotoRepository()
        let saved = try await useCase(posts, photos).execute(post: post(), photo: jpeg)
        #expect(saved.photo == jpeg)
        #expect(await posts.stored[PostID("p1")]?.photo == jpeg)
        let shared = try #require(await photos.stored[PostID("p1")])
        #expect(shared.photo == jpeg && shared.caption == "Treino C · Pernas" && shared.logID == LogID("log-1") && shared.studentID == "s1")
        #expect(shared.takenAt == when)
    }

    @Test("Nothing about the card except the picture, its title and day reaches the shared copy — not the songs")
    func keepsTheMusicPrivate() async throws {
        let photos = InMemorySharedPhotoRepository()
        _ = try await useCase(InMemoryPostRepository(), photos).execute(post: post(), photo: jpeg)
        let encoded = String(decoding: try JSONEncoder().encode(try #require(await photos.stored[PostID("p1")])), as: UTF8.self)
        #expect(!encoded.contains("Private song") && !encoded.contains("Someone"))
    }

    @Test("Removing the photo clears the card and removes the shared copy; changing it replaces the copy")
    func removesAndReplaces() async throws {
        let posts = InMemoryPostRepository(), photos = InMemorySharedPhotoRepository()
        let uc = useCase(posts, photos)
        _ = try await uc.execute(post: post(), photo: jpeg)
        _ = try await uc.execute(post: post(), photo: Data([1]))
        #expect(await photos.stored[PostID("p1")]?.photo == Data([1]))
        let cleared = try await uc.execute(post: post(), photo: nil)
        let cardPhoto = await posts.stored[PostID("p1")]?.photo
        let sharedLeft = await photos.stored.count
        let removedIDs = await photos.removed
        #expect(cleared.photo == nil && cardPhoto == nil)
        #expect(sharedLeft == 0 && removedIDs == [PostID("p1")])
    }

    @Test("A card made from no workout (the playlist of the day) still shares its photo, without a workout link")
    func noWorkout() async throws {
        let photos = InMemorySharedPhotoRepository()
        _ = try await useCase(InMemoryPostRepository(), photos).execute(post: post("playlist", log: nil), photo: jpeg)
        #expect(await photos.stored[PostID("playlist")]?.logID == nil)
    }

    @Test("If mirroring fails the error is surfaced, so the screen can say the photo wasn't shared")
    func failure() async throws {
        let photos = InMemorySharedPhotoRepository()
        await photos.setFailing(true)
        await #expect(throws: InMemorySharedPhotoRepository.Boom.self) { try await useCase(InMemoryPostRepository(), photos).execute(post: post(), photo: jpeg) }
    }
}

