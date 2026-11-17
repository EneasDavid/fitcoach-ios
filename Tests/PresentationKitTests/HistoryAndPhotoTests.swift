import Domain
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PresentationKit

/// A log repository whose stream the test controls.
final class StreamingLogs: WorkoutLogRepository, @unchecked Sendable {
    let pipe = Pipe<[WorkoutLog]>()
    func save(_ log: WorkoutLog) async throws -> WorkoutLog { log }
    func log(id: LogID, studentID: UserID) async throws -> WorkoutLog? { nil }
    func logs(studentID: UserID, planID: PlanID?, since: Date?) async throws -> [WorkoutLog] { [] }
    func observeLogs(studentID: UserID) -> AsyncStream<[WorkoutLog]> { pipe.stream() }
}

final class RecordingPhotos: SharedPhotoRepository, @unchecked Sendable {
    let pipe = Pipe<[SharedPhoto]>()
    private let lock = NSLock()
    private var saved: [SharedPhoto] = []
    private var removed: [PostID] = []
    var savedPhotos: [SharedPhoto] { lock.withLock { saved } }
    var removedIDs: [PostID] { lock.withLock { removed } }
    func save(_ photo: SharedPhoto) async throws -> SharedPhoto { lock.withLock { saved.append(photo) }; return photo }
    func remove(id: PostID, studentID: UserID) async throws { lock.withLock { removed.append(id) } }
    func photos(studentID: UserID) async throws -> [SharedPhoto] { [] }
    func observePhotos(studentID: UserID) -> AsyncStream<[SharedPhoto]> { pipe.stream() }
}

final class RecordingPosts: PostRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [ActivityPost] = []
    private var failing = false
    var savedPosts: [ActivityPost] { lock.withLock { saved } }
    func failSaves(_ value: Bool) { lock.withLock { failing = value } }
    func save(_ post: ActivityPost) async throws -> ActivityPost {
        if lock.withLock({ failing }) { throw MemLogRepo.Failure() }
        lock.withLock { saved.append(post) }
        return post
    }
    func posts(studentID: UserID) async throws -> [ActivityPost] { [] }
    func observePosts(studentID: UserID) -> AsyncStream<[ActivityPost]> { AsyncStream { $0.finish() } }
}

enum HistoryFx {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }

    static func date(_ month: Int, _ day: Int, hour: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!
    }

    /// Friday 15 March 2024.
    static let now = date(3, 15, hour: 12)

    static func session(_ id: String, _ month: Int, _ day: Int, hour: Int = 18, status: WorkoutStatus = .completed, sets: [SetLog] = [],
                        minutes: Int = 50, deleted: Bool = false) -> WorkoutLog {
        let start = date(month, day, hour: hour)
        var log = WorkoutLog(id: LogID(id), planID: "plan-1", templateID: "tpl-a", templateLabel: "Workout A", studentID: PFx.student,
                             status: status, startedAt: start, completedAt: status == .completed ? start.addingTimeInterval(Double(minutes) * 60) : nil,
                             blocks: sets.isEmpty ? [] : [.resistance(ResistanceLog(blockID: "blk-squat", exercise: PFx.squat, sets: sets))],
                             sessionRPE: 8, meta: PFx.meta())
        if deleted { log.meta.deletedAt = start }
        return log
    }

    static func set(_ index: Int, kg: Double, reps: Int, warmup: Bool = false) -> SetLog {
        SetLog(index: index, weightKg: kg, reps: reps, completedAt: date(3, 12), isWarmup: warmup)
    }

    @MainActor
    static func loaded(_ logs: [WorkoutLog]) async -> (HistoryViewModel, Task<Void, Never>) {
        let repo = StreamingLogs()
        let model = HistoryViewModel(studentID: PFx.student, logs: repo, calendar: calendar, now: { now })
        let task = Task { await model.run() }
        repo.pipe.send(logs)
        _ = await FeedFx.wait { model.isLoaded }
        return (model, task)
    }
}

@Suite("History calendar")
@MainActor
struct HistoryTests {
    typealias Fx = HistoryFx

    var march: [WorkoutLog] {
        [Fx.session("a", 3, 5),
         Fx.session("b", 3, 12, hour: 8, sets: [Fx.set(1, kg: 40, reps: 10, warmup: true), Fx.set(2, kg: 80, reps: 5), Fx.set(3, kg: 80, reps: 5)]),
         Fx.session("c", 3, 12, hour: 19),
         Fx.session("skipped", 3, 8, status: .skipped),
         Fx.session("running", 3, 9, status: .inProgress),
         Fx.session("gone", 3, 10, deleted: true),
         Fx.session("feb", 2, 20)]
    }

    @Test("Only finished, live workouts mark a day, and a day with two sessions says so")
    func marksDays() async {
        let (model, task) = await Fx.loaded(march)
        defer { task.cancel() }
        let marked = model.cells.compactMap { $0 }.filter(\.hasWorkout)
        #expect(marked.map(\.number) == [5, 12])
        #expect(marked.map(\.sessionCount) == [1, 2])
    }

    @Test("March 2024 starts on a Friday: five blanks on a Sunday-first calendar, 31 days after them, today is flagged")
    func grid() async {
        let (model, task) = await Fx.loaded([])
        defer { task.cancel() }
        #expect(model.cells.count == 5 + 31)
        #expect(model.cells.prefix(5).allSatisfy { $0 == nil })
        #expect(model.cells.compactMap { $0 }.filter(\.isToday).map(\.number) == [15])
        #expect(model.monthTitle == "March 2024")
    }

    @Test("Weekday letters start where the region's week starts")
    func weekdays() async {
        let (sunday, t1) = await Fx.loaded([])
        defer { t1.cancel() }
        #expect(sunday.weekdaySymbols.first == "S" && sunday.weekdaySymbols.count == 7)

        var monday = Fx.calendar
        monday.firstWeekday = 2
        let model = HistoryViewModel(studentID: PFx.student, logs: StreamingLogs(), calendar: monday, now: { Fx.now })
        #expect(model.weekdaySymbols == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(model.cells.prefix(while: { $0 == nil }).count == 4)       // Friday is the fifth column when the week starts on Monday
    }

    @Test("The list opens on the latest day with a workout, and tapping another day switches it")
    func selection() async {
        let (model, task) = await Fx.loaded(march)
        defer { task.cancel() }
        #expect(model.selectedSessions.map(\.id.rawValue) == ["b", "c"])           // 12 March, earliest first
        model.select(Fx.date(3, 5, hour: 3))
        #expect(model.selectedSessions.map(\.id.rawValue) == ["a"])
        model.select(Fx.date(3, 6))
        #expect(model.selectedSessions.isEmpty)
    }

    @Test("A session sums working sets only — warm-ups are not volume — and shows time and effort")
    func sessionDetails() async throws {
        let (model, task) = await Fx.loaded(march)
        defer { task.cancel() }
        let session = try #require(model.selectedSessions.first)
        #expect(session.sets == 2)
        #expect(session.volumeKg == 800)
        #expect(session.minutes == 50 && session.rpe == 8 && session.title == "Workout A")
    }

    @Test("Months move back freely but never into the future; each lands on its own latest workout")
    func navigation() async {
        let (model, task) = await Fx.loaded(march)
        defer { task.cancel() }
        #expect(model.canGoForward == false)
        model.nextMonth()
        #expect(model.monthTitle == "March 2024")
        model.previousMonth()
        #expect(model.monthTitle == "February 2024" && model.canGoForward)
        #expect(model.selectedSessions.map(\.id.rawValue) == ["feb"])
        model.nextMonth()
        #expect(model.monthTitle == "March 2024")
    }

    @Test("The month summary counts workouts and distinct training days")
    func summary() async {
        let (model, task) = await Fx.loaded(march)
        defer { task.cancel() }
        #expect(model.monthSummary.workouts == 3 && model.monthSummary.days == 2)
        model.previousMonth()
        #expect(model.monthSummary.workouts == 1 && model.monthSummary.days == 1)
    }

    @Test("A day identifier is stable and sortable, for UI automation")
    func identifier() {
        #expect(HistoryViewModel.identifier(for: Fx.date(3, 5), calendar: Fx.calendar) == "2024-03-05")
    }

    @Test("The screen renders with and without workouts")
    func renders() async {
        let (full, t1) = await Fx.loaded(march)
        defer { t1.cancel() }
        _ = HistoryView(model: full, profileButton: AnyView(EmptyView())).body
        let (empty, t2) = await Fx.loaded([])
        defer { t2.cancel() }
        _ = HistoryView(model: empty, profileButton: AnyView(EmptyView())).body
    }
}

@Suite("Feed photo")
@MainActor
struct FeedPhotoTests {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    @Test("A picked photo is shrunk by the processor and saved on that card only")
    func attaches() async {
        let repo = RecordingPosts()
        let model = FeedViewModel(studentID: PFx.student, posts: repo, processPhoto: { _ in Data([1, 2]) })
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(repo.savedPosts.map(\.id.rawValue) == ["a"])
        #expect(repo.savedPosts.first?.photo == Data([1, 2]))
        #expect(model.errorMessage == nil)
    }

    @Test("Removing the photo clears it without touching the processor")
    func removes() async {
        let repo = RecordingPosts()
        var processed = 0
        let model = FeedViewModel(studentID: PFx.student, posts: repo, processPhoto: { processed += 1; return $0 })
        var post = FeedFx.post("a"); post.photo = jpeg
        await model.setPhoto(nil, on: post)
        #expect(repo.savedPosts.first?.photo == nil && processed == 0)
    }

    @Test("An unusable image is refused with a message and nothing is saved")
    func unusable() async {
        let repo = RecordingPosts()
        let model = FeedViewModel(studentID: PFx.student, posts: repo, processPhoto: { _ in nil })
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(repo.savedPosts.isEmpty && model.errorMessage != nil)
    }

    @Test("A failed save is reported, and the next success clears the message")
    func saveFailure() async {
        let repo = RecordingPosts()
        let model = FeedViewModel(studentID: PFx.student, posts: repo)
        repo.failSaves(true)
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(model.errorMessage != nil)
        repo.failSaves(false)
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(model.errorMessage == nil && repo.savedPosts.count == 1)
    }

    @Test("With a trainer-visible copy configured, the photo is mirrored; removing it removes the copy")
    func mirrorsToTheTrainer() async {
        let posts = RecordingPosts(), photos = RecordingPhotos()
        let model = FeedViewModel(studentID: PFx.student, posts: posts, photos: photos, processPhoto: { _ in Data([7]) })
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(posts.savedPosts.first?.photo == Data([7]))
        #expect(photos.savedPhotos.map(\.id.rawValue) == ["a"] && photos.savedPhotos.first?.photo == Data([7]))
        await model.setPhoto(nil, on: FeedFx.post("a"))
        #expect(photos.removedIDs.map(\.rawValue) == ["a"])
        #expect(model.errorMessage == nil)
    }

    @Test("An unusable image shares nothing")
    func unusableSharesNothing() async {
        let posts = RecordingPosts(), photos = RecordingPhotos()
        let model = FeedViewModel(studentID: PFx.student, posts: posts, photos: photos, processPhoto: { _ in nil })
        await model.setPhoto(jpeg, on: FeedFx.post("a"))
        #expect(photos.savedPhotos.isEmpty && posts.savedPosts.isEmpty && model.errorMessage != nil)
    }

    @Test("A card with a photo renders on the feed and on the share poster")
    func rendersWithPhoto() {
        var post = FeedFx.post("p"); post.photo = ProfilePhotoFixture.jpeg
        _ = PostCardView(post: post).body
        _ = PostCardView(post: post, style: .share).body
    }
}

enum ProfilePhotoFixture {
    /// A real 8 × 8 JPEG, so the view's image decoding path runs.
    @MainActor static var jpeg: Data {
        let renderer = ImageRenderer(content: Color.green.frame(width: 8, height: 8))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

@Suite("Trainer's student photos")
@MainActor
struct StudentPhotosTests {
    func photo(_ id: String, day: Double, log: String? = nil, bytes: [UInt8] = [1]) -> SharedPhoto {
        SharedPhoto(id: PostID(id), studentID: PFx.student, logID: log.map { LogID($0) }, takenAt: PFx.t0.addingTimeInterval(day * 86_400),
                    caption: "Treino \(id)", photo: Data(bytes), meta: PFx.meta())
    }

    @Test("Photos arrive newest first; empty or removed ones never show")
    func streams() async {
        let repo = RecordingPhotos()
        let model = StudentPhotosViewModel(studentID: PFx.student, photos: repo)
        #expect(model.isEmpty == false)                                 // not loaded yet is not "empty"
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send([])
        #expect(await FeedFx.wait { model.isEmpty })
        var gone = photo("gone", day: 2); gone.meta.deletedAt = PFx.t0
        repo.pipe.send([photo("old", day: 0), photo("new", day: 1), photo("blank", day: 3, bytes: []), gone])
        #expect(await FeedFx.wait { model.photos.count == 2 })
        #expect(model.photos.map(\.id.rawValue) == ["new", "old"])
    }

    @Test("A day's workout finds its own photos")
    func perWorkout() async {
        let repo = RecordingPhotos()
        let model = StudentPhotosViewModel(studentID: PFx.student, photos: repo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send([photo("a", day: 1, log: "log-1"), photo("b", day: 2, log: "log-2"), photo("c", day: 3)])
        #expect(await FeedFx.wait { model.photos.count == 3 })
        #expect(model.photos(forLog: "log-1").map(\.id.rawValue) == ["a"])
        #expect(model.photos(forLog: "log-9").isEmpty)
    }

    @Test("A photo that gets removed while it is open closes the viewer")
    func removalClosesViewer() async {
        let repo = RecordingPhotos()
        let model = StudentPhotosViewModel(studentID: PFx.student, photos: repo)
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send([photo("a", day: 1)])
        #expect(await FeedFx.wait { model.photos.count == 1 })
        model.selected = model.photos.first
        repo.pipe.send([])
        #expect(await FeedFx.wait { model.selected == nil })
    }

    @Test("The gallery renders with photos and without")
    func renders() async {
        let repo = RecordingPhotos()
        let model = StudentPhotosViewModel(studentID: PFx.student, photos: repo)
        _ = StudentPhotosView(model: model).body
        let task = Task { await model.run() }
        defer { task.cancel() }
        repo.pipe.send([photo("a", day: 1, bytes: [UInt8](ProfilePhotoFixture.jpeg))])
        #expect(await FeedFx.wait { model.photos.count == 1 })
        _ = StudentPhotosView(model: model).body
    }
}

