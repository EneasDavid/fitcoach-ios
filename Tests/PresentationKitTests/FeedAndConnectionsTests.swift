import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

/// A repository-side stream whose values the test controls.
final class Pipe<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<T>.Continuation] = []
    private var last: T?

    init(initial: T? = nil) { last = initial }

    func stream() -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream()
        let initial = lock.withLock { () -> T? in continuations.append(continuation); return last }
        if let initial { continuation.yield(initial) }
        return stream
    }

    func send(_ value: T) {
        let targets = lock.withLock { () -> [AsyncStream<T>.Continuation] in last = value; return continuations }
        targets.forEach { $0.yield(value) }
    }
}

final class FakePosts: PostRepository, @unchecked Sendable {
    let pipe = Pipe<[ActivityPost]>()
    func save(_ post: ActivityPost) async throws -> ActivityPost { post }
    func posts(studentID: UserID) async throws -> [ActivityPost] { [] }
    func observePosts(studentID: UserID) -> AsyncStream<[ActivityPost]> { pipe.stream() }
}

final class FakePrefs: SharingPreferencesRepository, @unchecked Sendable {
    let pipe: Pipe<SharingPreferences>
    private let lock = NSLock()
    private var failing = false
    private var saved: [SharingPreferences] = []
    let initial: SharingPreferences

    init(_ initial: SharingPreferences) { self.initial = initial; pipe = Pipe(initial: initial) }
    var savedValues: [SharingPreferences] { lock.withLock { saved } }
    func failSaves(_ value: Bool) { lock.withLock { failing = value } }

    func preferences(studentID: UserID) async throws -> SharingPreferences { initial }
    func save(_ preferences: SharingPreferences) async throws -> SharingPreferences {
        if lock.withLock({ failing }) { throw ConnectionFailure.signInFailed }
        lock.withLock { saved.append(preferences) }
        pipe.send(preferences)
        return preferences
    }
    func observePreferences(studentID: UserID) -> AsyncStream<SharingPreferences> { pipe.stream() }
}

final class FakeLinks: IntegrationLinkRepository, @unchecked Sendable {
    let pipe = Pipe<[IntegrationLink]>(initial: [])
    func link(provider: IntegrationProvider, studentID: UserID) async throws -> IntegrationLink? { nil }
    func observeLinks(studentID: UserID) -> AsyncStream<[IntegrationLink]> { pipe.stream() }
}

@MainActor
final class FakeActions: ConnectionsActions {
    var current = ConnectionStatus(spotifyAvailable: true, stravaAvailable: true)
    var failure: Error?
    private(set) var calls: [String] = []

    func status() async -> ConnectionStatus { current }
    func setGymDetection(enabled: Bool) async throws {
        calls.append("gym:\(enabled)")
        if let failure { throw failure }
        current.gymDetectionOn = enabled
        current.gymName = enabled ? "Smart Fit Centro" : nil
    }
    func connectSpotify() async throws {
        calls.append("spotify:connect")
        if let failure { throw failure }
        current.spotifyConnected = true
    }
    func disconnectSpotify() async { calls.append("spotify:disconnect"); current.spotifyConnected = false }
    func connectStrava() async throws { calls.append("strava:connect"); if let failure { throw failure } }
    func disconnectStrava() async throws { calls.append("strava:disconnect"); if let failure { throw failure } }
}

enum FeedFx {
    static func post(_ id: String, kind: PostKind = .workout) -> ActivityPost {
        ActivityPost(id: PostID(id), studentID: PFx.student, kind: kind, createdAt: PFx.t0, title: "Title \(id)", subtitle: "85 kg × 5",
                     stats: [PostStat(label: "Sets", value: "9"), PostStat(label: "Time", value: "52 min")],
                     tracks: [PostTrack(title: "Eye of the Tiger", artist: "Survivor", plays: 3, note: "Playing when you hit it")], meta: PFx.meta())
    }

    static func prefs() -> SharingPreferences { SharingPreferences(studentID: PFx.student, meta: PFx.meta()) }

    static func wait(_ condition: @MainActor @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

@Suite("Feed")
@MainActor
struct FeedTests {
    @Test("Empty until the first emission says so; then shows posts as they arrive")
    func streams() async {
        let repo = FakePosts()
        let model = FeedViewModel(studentID: PFx.student, posts: repo)
        #expect(model.isEmpty == false)                       // not loaded yet is not "empty"
        let task = Task { await model.run() }
        repo.pipe.send([])
        #expect(await FeedFx.wait { model.isEmpty })
        repo.pipe.send([FeedFx.post("a"), FeedFx.post("b")])
        #expect(await FeedFx.wait { model.posts.count == 2 })
        #expect(model.isEmpty == false)
        task.cancel()
    }

    @Test("Every kind has an icon and a name, and every destination a label")
    func labels() {
        for kind in [PostKind.workout, .personalRecord, .playlistOfTheDay, .externalActivity] {
            #expect(!kind.systemImage.isEmpty && !kind.displayName.isEmpty)
        }
        #expect(ShareDestination.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("Cards and sheets build in every state")
    func viewsBuild() {
        for kind in [PostKind.workout, .personalRecord, .playlistOfTheDay, .externalActivity] {
            _ = PostCardView(post: FeedFx.post("x", kind: kind)).body
            _ = PostCardView(post: FeedFx.post("x", kind: kind), style: .share).body
        }
        var bare = FeedFx.post("bare"); bare.subtitle = nil; bare.stats = []; bare.tracks = []
        _ = PostCardView(post: bare).body
        _ = PostCardView(post: bare, style: .share).body
        _ = FeedView(model: FeedViewModel(studentID: PFx.student, posts: FakePosts()), onShare: { _ in }).body
        _ = ShareDestinationSheet(post: FeedFx.post("x"), isAvailable: { $0 != .instagramStories }, onSelect: { _ in }).body
    }

    @Test("The share poster renders to a 1080 × 1920 image")
    func rendersPoster() {
        let renderer = ImageRenderer(content: PostCardView(post: FeedFx.post("share", kind: .personalRecord), style: .share))
        renderer.scale = 3
        #expect(renderer.cgImage?.width == 1_080 && renderer.cgImage?.height == 1_920)
    }
}

@Suite("Connections")
@MainActor
struct ConnectionsTests {
    func make(_ given: FakeActions? = nil) -> (ConnectionsViewModel, FakeActions, FakePrefs, FakeLinks) {
        let actions = given ?? FakeActions()
        let prefs = FakePrefs(FeedFx.prefs())
        let links = FakeLinks()
        return (ConnectionsViewModel(studentID: PFx.student, actions: actions, preferences: prefs, links: links, now: PFx.t0), actions, prefs, links)
    }

    @Test("Everything starts off, and the build's capabilities come from the app")
    func defaults() async {
        let (model, _, _, _) = make()
        let task = Task { await model.run() }
        #expect(await FeedFx.wait { model.status.spotifyAvailable })
        #expect(model.preferences.includeMusicInPosts == false && model.preferences.shareStravaWithTrainer == false)
        #expect(model.status.gymDetectionOn == false && model.stravaConnected == false)
        task.cancel()
    }

    @Test("The student's switches are saved; a failed save puts the switch back and says so")
    func switches() async {
        let (model, _, prefs, _) = make()
        await model.setIncludeMusic(true)
        #expect(model.preferences.includeMusicInPosts)
        #expect(prefs.savedValues.last?.includeMusicInPosts == true)
        await model.setIncludeMusic(true)                      // no change → no write
        #expect(prefs.savedValues.count == 1)

        prefs.failSaves(true)
        await model.setShareStravaWithTrainer(true)
        #expect(model.preferences.shareStravaWithTrainer == false)
        #expect(model.errorMessage != nil)
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test("Gym detection is switched through the app, and status is re-read afterwards")
    func gym() async {
        let (model, actions, _, _) = make()
        await model.setGymDetection(true)
        #expect(actions.calls == ["gym:true"])
        #expect(model.status.gymDetectionOn && model.status.gymName == "Smart Fit Centro")
        #expect(model.busy == nil)
    }

    @Test("Failures are explained in plain words; closing the sign-in sheet is silent")
    func errors() async {
        let (model, actions, _, _) = make()
        actions.failure = ConnectionFailure.cancelled
        await model.connectSpotify()
        #expect(model.errorMessage == nil)

        actions.failure = ConnectionFailure.permissionDenied
        await model.setGymDetection(true)
        #expect(model.errorMessage?.contains("Location") == true)

        actions.failure = ConnectionFailure.signInFailed
        await model.connectStrava()
        #expect(model.errorMessage != nil && model.busy == nil)

        actions.failure = URLError(.notConnectedToInternet)
        await model.connectStrava()
        #expect(model.errorMessage != nil)
    }

    @Test("Strava 'connected' follows the server's link; disconnecting also withdraws consent to share")
    func strava() async {
        let (model, actions, prefs, links) = make()
        let task = Task { await model.run() }
        await model.setShareStravaWithTrainer(true)
        #expect(await FeedFx.wait { prefs.savedValues.count == 1 })

        links.pipe.send([IntegrationLink(studentID: PFx.student, provider: .strava, isConnected: true, meta: PFx.meta())])
        #expect(await FeedFx.wait { model.stravaConnected })

        await model.disconnectStrava()
        #expect(actions.calls.contains("strava:disconnect"))
        #expect(model.preferences.shareStravaWithTrainer == false)
        #expect(prefs.savedValues.last?.shareStravaWithTrainer == false)

        links.pipe.send([IntegrationLink(studentID: PFx.student, provider: .strava, isConnected: false, meta: PFx.meta())])
        #expect(await FeedFx.wait { !model.stravaConnected })
        task.cancel()
    }

    @Test("Spotify can be connected and disconnected")
    func spotify() async {
        let (model, actions, _, _) = make()
        await model.connectSpotify()
        #expect(model.status.spotifyConnected)
        await model.disconnectSpotify()
        #expect(actions.calls == ["spotify:connect", "spotify:disconnect"] && !model.status.spotifyConnected)
    }

    @Test("The screen builds in each state")
    func viewBuilds() async {
        let actions = FakeActions()
        let (model, _, _, _) = make(actions)
        _ = ConnectionsView(model: model, gymPicker: { AnyView(EmptyView()) }).body
        actions.current = ConnectionStatus(gymDetectionOn: true, gymName: "Gym", spotifyAvailable: true, spotifyConnected: true, stravaAvailable: true)
        let task = Task { await model.run() }
        #expect(await FeedFx.wait { model.status.spotifyConnected })
        _ = ConnectionsView(model: model, gymPicker: { AnyView(EmptyView()) }).body
        await model.setGymDetection(true)
        _ = ConnectionsView(model: model, gymPicker: { AnyView(EmptyView()) }).body
        task.cancel()
        _ = ConnectionsView(model: ConnectionsViewModel(studentID: PFx.student, actions: FakeActions(), preferences: FakePrefs(FeedFx.prefs()), links: FakeLinks()),
                            gymPicker: { AnyView(EmptyView()) }).body
    }
}

@Suite("Activity report")
@MainActor
struct ActivityReportTests {
    final class Activities: ExternalActivityRepository, @unchecked Sendable {
        var items: [ExternalActivity] = []
        func activities(studentID: UserID, since: Date?) async throws -> [ExternalActivity] { items.filter { since == nil || $0.startedAt >= since! } }
        func observeActivities(studentID: UserID) -> AsyncStream<[ExternalActivity]> { AsyncStream { $0.finish() } }
    }

    func run(_ id: String, daysAgo: Double, now: Date) -> ExternalActivity {
        ExternalActivity(studentID: PFx.student, externalID: id, sportType: "Run", name: "Run \(id)", startedAt: now.addingTimeInterval(-daysAgo * 86_400),
                         movingSeconds: 1_800, elapsedSeconds: 1_800, distanceMeters: 5_000, meta: PFx.meta())
    }

    @Test("Combines app workouts and Strava runs, and the period filters what is shown")
    func report() async {
        let now = PFx.t0.addingTimeInterval(40 * 86_400)
        let logs = MemLogRepo()
        await logs.seed(PFx.log(id: "recent", status: .completed, start: now.addingTimeInterval(-2 * 86_400)))
        await logs.seed(PFx.log(id: "older", status: .completed, start: now.addingTimeInterval(-20 * 86_400)))
        let activities = Activities()
        activities.items = [run("1", daysAgo: 1, now: now), run("2", daysAgo: 15, now: now)]

        let model = ActivityReportViewModel(studentID: PFx.student, logs: logs, activities: activities, now: { now })
        await model.load()
        #expect(model.report?.sessions == 2)                    // last 7 days: one workout + one run
        #expect(model.hasStravaEntries)
        #expect(model.report?.totalDistanceMeters == 5_000)

        await model.select(.month)
        #expect(model.period == .month)
        #expect(model.report?.sessions == 4)
        #expect(model.report?.entries.first?.date == model.report?.entries.map(\.date).max())
    }

    @Test("No Strava entries is reported as such, and the view builds with and without data")
    func empty() async {
        let model = ActivityReportViewModel(studentID: PFx.student, logs: MemLogRepo(), activities: Activities(), now: { PFx.t0 })
        _ = ActivityReportView(model: model).body
        await model.load()
        #expect(model.report?.sessions == 0 && model.hasStravaEntries == false)
        _ = ActivityReportView(model: model).body
        #expect(ActivityReportViewModel.Period.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite("Gym picker")
@MainActor
struct GymPickerTests {
    struct FixedLocator: GymLocating {
        var gyms: [GymVenue] = []
        var failure: Error?
        func gyms(near latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [GymVenue] {
            if let failure { throw failure }
            return gyms
        }
    }

    // Two gyms around Maceió: ~0.4 km and ~2.2 km north of the origin.
    let near = GymVenue(id: "near", name: "Near", latitude: -9.6658 + 0.0036, longitude: -35.7353)
    let far = GymVenue(id: "far", name: "Far", latitude: -9.6658 + 0.0200, longitude: -35.7353)
    let here: (latitude: Double, longitude: Double) = (-9.6658, -35.7353)

    @Test("Haversine distance is accurate at gym scale and symmetric")
    func distance() {
        let meters = near.distanceMeters(toLatitude: here.latitude, longitude: here.longitude)
        #expect(abs(meters - 400) < 5)                                                    // 0.0036° of latitude ≈ 400 m
        let back = GymVenue(id: "o", name: "o", latitude: here.latitude, longitude: here.longitude)
        #expect(abs(back.distanceMeters(toLatitude: near.latitude, longitude: near.longitude) - meters) < 0.001)
        #expect(near.distanceMeters(toLatitude: near.latitude, longitude: near.longitude) == 0)
    }

    @Test("Results come nearest first, with readable distances")
    func sorted() async {
        let model = GymPickerViewModel(locator: FixedLocator(gyms: [far, near]), currentLocation: { [here] in here }, onSelect: { _ in })
        await model.load()
        guard case .results(let gyms) = model.state else { Issue.record("expected results"); return }
        #expect(gyms.map(\.id) == ["near", "far"])
        #expect(model.distanceText(for: near)?.hasSuffix("m") == true)
        #expect(model.distanceText(for: far)?.hasSuffix("km") == true)
    }

    @Test("Choosing hands the venue to the app; a failing save is surfaced")
    func choosing() async {
        var picked: [String] = []
        let model = GymPickerViewModel(locator: FixedLocator(gyms: [near]), currentLocation: { [here] in here }, onSelect: { picked.append($0.id) })
        await model.load()
        await model.choose(near)
        #expect(picked == ["near"] && model.chosen == near)

        struct Nope: Error {}
        let failing = GymPickerViewModel(locator: FixedLocator(gyms: [near]), currentLocation: { [here] in here }, onSelect: { _ in throw Nope() })
        await failing.choose(near)
        #expect(failing.chosen == nil && failing.state == .unavailable)
    }

    @Test("Empty, denied and offline each get their own state")
    func states() async {
        let empty = GymPickerViewModel(locator: FixedLocator(), currentLocation: { [here] in here }, onSelect: { _ in })
        await empty.load()
        #expect(empty.state == .empty)

        let denied = GymPickerViewModel(locator: FixedLocator(), currentLocation: { throw ConnectionFailure.permissionDenied }, onSelect: { _ in })
        await denied.load()
        #expect(denied.state == .failed(.permissionDenied))

        let offline = GymPickerViewModel(locator: FixedLocator(failure: URLError(.notConnectedToInternet)), currentLocation: { [here] in here }, onSelect: { _ in })
        await offline.load()
        #expect(offline.state == .unavailable)
        #expect(offline.distanceText(for: near) != nil)           // origin was resolved before the lookup failed
    }

    @Test("The picker builds in every state")
    func viewBuilds() async {
        for locator in [FixedLocator(gyms: [near, far]), FixedLocator(), FixedLocator(failure: URLError(.timedOut))] {
            let model = GymPickerViewModel(locator: locator, currentLocation: { [here] in here }, onSelect: { _ in })
            _ = GymPickerView(model: model).body
            await model.load()
            _ = GymPickerView(model: model).body
        }
        let denied = GymPickerViewModel(locator: FixedLocator(), currentLocation: { throw ConnectionFailure.permissionDenied }, onSelect: { _ in })
        await denied.load()
        _ = GymPickerView(model: denied).body
    }
}

struct StubAuth: AuthenticationService {
    var result: Result<SignedInUser, AuthenticationError>
    func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser { try result.get() }
}

@Suite("Sign-in & profile")
@MainActor
struct AccountTests {
    final class Capture { var user: SignedInUser?; var logouts = 0; var pending = 0 }

    func signIn(_ result: Result<SignedInUser, AuthenticationError>, _ capture: Capture) -> SignInViewModel {
        SignInViewModel(auth: StubAuth(result: result), onSignedIn: { capture.user = $0 })
    }

    @Test("The screen says which door it is opening as the identifier is typed; it can't submit without a password")
    func detection() {
        let model = signIn(.failure(.invalidCredentials), Capture())
        #expect(model.detectedLabel == nil && !model.canSubmit)
        model.identifier = "529.982.247-25"
        #expect(model.detectedRole == .student && model.detectedLabel?.contains("CPF") == true)
        #expect(!model.canSubmit)                                             // no password yet
        model.password = "secret"
        #expect(model.canSubmit)
        model.identifier = "012345-G/AL"
        #expect(model.detectedRole == .trainer && model.detectedLabel?.contains("CREF") == true)
        model.identifier = "nonsense"
        #expect(model.detectedRole == nil && !model.canSubmit)
    }

    @Test("Signing in hands the server-verified user to the app, whatever the identifier looked like")
    func signsIn() async {
        let capture = Capture()
        let serverSaysStudent = SignedInUser(userID: "u1", role: .student, displayName: "Ana Souza")
        let model = signIn(.success(serverSaysStudent), capture)
        model.identifier = "012345-G/AL"                                      // looks like a trainer…
        model.password = "pw"
        await model.submit()
        #expect(capture.user == serverSaysStudent)                            // …but the backend's answer is what routes
        #expect(model.password.isEmpty && model.errorMessage == nil && !model.isWorking)
    }

    @Test("Each failure has its own plain message and nothing is signed in", arguments: [
        AuthenticationError.invalidCredentials, .notConfigured, .offline,
    ])
    func failures(error: AuthenticationError) async {
        let capture = Capture()
        let model = signIn(.failure(error), capture)
        model.identifier = "529.982.247-25"; model.password = "pw"
        await model.submit()
        #expect(model.errorMessage?.isEmpty == false && capture.user == nil && !model.isWorking)
    }

    @Test("Submitting an invalid form does nothing")
    func guarded() async {
        let capture = Capture()
        let model = signIn(.success(SignedInUser(userID: "u", role: .student, displayName: "x")), capture)
        await model.submit()
        #expect(capture.user == nil)
    }

    func profile(_ capture: Capture, name: String = "Ana Souza") -> ProfileViewModel {
        ProfileViewModel(name: name, role: .student, pendingChanges: { capture.pending }, signOut: { capture.logouts += 1 })
    }

    @Test("Log out is immediate when everything is synced, and asks first when edits are still waiting")
    func logout() async {
        let capture = Capture()
        let model = profile(capture)
        await model.requestLogout()
        #expect(capture.logouts == 1 && !model.isConfirmingLogout)

        capture.pending = 3
        await model.requestLogout()
        #expect(capture.logouts == 1 && model.isConfirmingLogout && model.unsyncedChanges == 3)
        await model.confirmLogout()
        #expect(capture.logouts == 2 && !model.isConfirmingLogout)
    }

    @Test("Initials and role titles")
    func labels() {
        let capture = Capture()
        #expect(profile(capture).initials == "AS" && profile(capture, name: "madonna").initials == "M" && profile(capture, name: "").initials == "?")
        #expect(!profile(capture).roleTitle.isEmpty)
    }

    @Test("Sign-in, profile and the feed header build")
    func viewsBuild() {
        let capture = Capture()
        _ = SignInView(model: signIn(.failure(.offline), capture)).body
        _ = ProfileView(model: profile(capture), onOpenConnections: {}).body
        _ = ProfileView(model: profile(capture)).body
        _ = FeedView(model: FeedViewModel(studentID: PFx.student, posts: FakePosts()),
                     profileButton: AnyView(ProfileToolbarButton(initials: "AS", photo: nil, action: {})), onShare: { _ in }).body
        _ = Avatar(initials: "AS").body
        _ = Text("x").adaptiveContentWidth()
    }
}
