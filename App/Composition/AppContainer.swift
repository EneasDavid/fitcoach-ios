import DataKit
import Domain
import Foundation
import Observation
import PresentationKit
import SecurityKit
import SwiftData
import SwiftUI
import SyncKit

// NOT COMPILED IN THE AUTHORING ENVIRONMENT — see README → "Verification status".

enum AppEnvironment: Equatable {
    case production
    /// XCUITest launch (`-UITestMode`): in-memory stores, a loopback "server", a scriptable network, seeded data,
    /// no Firebase and no network access at all.
    case uiTesting(startOffline: Bool)

    /// `-UITestMode` (XCUITest / manual demo) or being hosted by a unit-test run → demo mode. A test host must never
    /// reach for Firebase or the real Keychain: there is no GoogleService-Info.plist and `FirebaseApp.configure()` would crash.
    static func detect(_ info: ProcessInfo = .processInfo) -> AppEnvironment {
        let arguments = info.arguments
        let hostedByTests = info.environment["XCTestConfigurationFilePath"] != nil
            || info.environment["XCTestBundlePath"] != nil
            || info.environment["XCTestSessionIdentifier"] != nil
        if arguments.contains("-UITestMode") || hostedByTests {
            return .uiTesting(startOffline: arguments.contains("-UITestOffline"))
        }
        return .production
    }
}

/// **Composition root** — the only place that knows every concrete type. Everything else depends on the
/// protocols in `Domain`, so swapping Firestore for another backend, or SwiftData for SQLite, is a change here.
///
/// Wiring, bottom-up:
///   Keychain ─► KeychainKeyProvider ─► FieldCipher ─► SealedRecordStore ─► OfflineFirstStore ─► repositories
///   SwiftData ─► SwiftDataMutationStore ─► MutationQueue ─► SyncDispatcher ─► (Firestore gateway)
@MainActor
@Observable
final class AppContainer {
    @MainActor static let shared: AppContainer = {
        do { return try AppContainer(AppEnvironment.detect()) } catch { fatalError("Could not build the app container: \(error)") }
    }()

    // Session
    private(set) var userID: UserID?
    private(set) var role: UserRole?
    private(set) var displayName = ""
    var pendingCheckInID: CheckInID?

    // Infrastructure
    let environment: AppEnvironment
    @ObservationIgnored let keyProvider: KeychainKeyProvider
    @ObservationIgnored let persistence: ModelContainer
    @ObservationIgnored let queue: MutationQueue
    @ObservationIgnored let dispatcher: SyncDispatcher
    @ObservationIgnored let network: any NetworkMonitoring
    @ObservationIgnored let scriptedNetwork: ControllableNetworkMonitor?
    @ObservationIgnored let router = NotificationRouter()

    // Aggregates
    @ObservationIgnored let logStore: OfflineFirstStore<WorkoutLog>
    @ObservationIgnored let planStore: OfflineFirstStore<WorkoutPlan>
    /// The student's own workouts plus the ones the trainer ran next to them, as one history (see `MergedWorkoutLogRepository`).
    @ObservationIgnored let logs: MergedWorkoutLogRepository
    @ObservationIgnored let plans: WorkoutPlanRepositoryImpl
    @ObservationIgnored let checkIns: CheckInRepositoryImpl
    @ObservationIgnored let bodyComposition: BodyCompositionRepositoryImpl
    @ObservationIgnored let posts: PostRepositoryImpl
    @ObservationIgnored let sharedPhotos: SharedPhotoRepositoryImpl
    @ObservationIgnored let trainerProfiles: TrainerProfileRepositoryImpl
    /// The CREF on the trainer's own profile (what their students see), once it is known.
    private(set) var trainerCREF: String?
    @ObservationIgnored let externalActivities: ExternalActivityRepositoryImpl
    @ObservationIgnored let integrationLinks: IntegrationLinkRepositoryImpl
    @ObservationIgnored let sharingPreferences: SharingPreferencesRepositoryImpl
    @ObservationIgnored let nicknames: NicknameRepositoryImpl
    @ObservationIgnored let registering: any StudentRegistering
    @ObservationIgnored let firstAccess: any FirstAccessService
    @ObservationIgnored let passwordReset: any PasswordResetting
    @ObservationIgnored let loginAliasing: (any LoginAliasing)?
    @ObservationIgnored private let registrationDirectory: RegistrationDirectory?        // demo / UI tests only
    /// Whether videos may start by themselves and whether the UI may animate (see `MediaPolicy`).
    @ObservationIgnored let mediaPolicy = MediaPolicy()
    @ObservationIgnored private var mediaObserver: MediaEnvironmentObserver?
    /// The signed-in person's photo (stored on this device only, encrypted).
    private(set) var profilePhoto: Data?

    // Integrations (all optional: a missing client id / backend URL just switches that integration off)
    let config = AppConfig.load()
    @ObservationIgnored let records: SealedRecordStore
    @ObservationIgnored let spotifyTokens: SpotifyTokenStore?
    @ObservationIgnored let backend: IntegrationBackendClient?
    @ObservationIgnored let gymLocator: any GymLocating

    // UI services
    @ObservationIgnored let componentFactory = WorkoutComponentFactory.standard()
    @ObservationIgnored let catalog: any ExerciseCatalogRepository
    @ObservationIgnored let feedback: SystemFeedback
    @ObservationIgnored let notifier: UserNotificationScheduler
    @ObservationIgnored let deviceID: String

    // Production-only
    @ObservationIgnored private var inbound: FirestoreInboundListener?
    @ObservationIgnored private var session: FirebaseSession?
    @ObservationIgnored private var arrival: GymArrivalCoordinator?
    @ObservationIgnored private var geofence: GeofenceDetector?
    @ObservationIgnored private var simulatedPresence: SimulatedGymPresenceProvider?
    @ObservationIgnored private var presence: GymPresenceCoordinator?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private let arrivalFactory: GymArrivalProviderFactory
    @ObservationIgnored private(set) var backgroundTasks: BackgroundTasks!
    @ObservationIgnored private let appliers: [String: any RemoteDocumentApplying]

    init(_ environment: AppEnvironment) throws {
        self.environment = environment
        let isProduction = environment == .production
        // Demo and UI-test launches always start from factory settings (data saver, remembered chart choices, gym switch): a value
        // left over from a previous run must never change what the next run does.
        if !isProduction, let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }

        // Security: secrets in the Keychain, two independent derived keys (records / queue).
        let secrets: any SecureStoring = isProduction ? KeychainStore(service: "com.fitcoach.app") : InMemorySecureStore()
        keyProvider = KeychainKeyProvider(store: secrets)
        let recordCipher = FieldCipher(keys: keyProvider, purpose: "records")
        let queueCipher = FieldCipher(keys: keyProvider, purpose: "mutation-queue")

        // Persistence (SwiftData behind the LocalRecordStore / MutationStore ports).
        persistence = try PersistenceContainerFactory.make(inMemory: !isProduction)
        let records = SealedRecordStore(inner: SwiftDataRecordStore(container: persistence), cipher: recordCipher)
        queue = MutationQueue(store: SwiftDataMutationStore(container: persistence, cipher: queueCipher))

        // Connectivity + backend.
        let gateway: any RemoteGateway
        switch environment {
        case .production:
            network = PathNetworkMonitor()
            scriptedNetwork = nil
            gateway = FirestoreRemoteGateway()
        case .uiTesting(let startOffline):
            let scripted = ControllableNetworkMonitor(online: !startOffline)
            network = scripted
            scriptedNetwork = scripted
            gateway = LoopbackGateway()
        }

        // Device identity for `meta.lastWriterDeviceID` (stable per install, not a hardware identifier).
        let deviceKey = "device.id"
        if let stored = try? secrets.data(forKey: deviceKey), let existing = String(data: stored, encoding: .utf8) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            try? secrets.set(Data(deviceID.utf8), forKey: deviceKey)
        }

        // Stores → dispatcher (broken cycle via DeferredSyncTrigger) → observer.
        let trigger = DeferredSyncTrigger()
        let deviceID = self.deviceID
        logStore = OfflineFirstStore(descriptor: .workoutLog, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        planStore = OfflineFirstStore(descriptor: .workoutPlan, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let checkInStore = OfflineFirstStore(descriptor: .checkIn, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let bodyStore = OfflineFirstStore(descriptor: .bodyCheckpoint, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let postStore = OfflineFirstStore(descriptor: .post, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let coachedLogStore = OfflineFirstStore(descriptor: .coachedLog, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let trainerProfileStore = OfflineFirstStore(descriptor: .trainerProfile, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let photoStore = OfflineFirstStore(descriptor: .sharedPhoto, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let activityStore = OfflineFirstStore(descriptor: .externalActivity, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let linkStore = OfflineFirstStore(descriptor: .integrationLink, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let prefsStore = OfflineFirstStore(descriptor: .sharingPreferences, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let nicknameStore = OfflineFirstStore(descriptor: .nickname, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        let registrationStore = OfflineFirstStore(descriptor: .registration, store: records, queue: queue, trigger: trigger, deviceID: deviceID)
        appliers = ["workoutLogs": logStore, "plans": planStore, "checkIns": checkInStore, "bodyCheckpoints": bodyStore,
                    "posts": postStore, "externalActivities": activityStore, "integrations": linkStore, "sharing": prefsStore,
                    "nicknames": nicknameStore, "registrations": registrationStore, "sharedPhotos": photoStore,
                    "trainerProfiles": trainerProfileStore, "coachedLogs": coachedLogStore]

        let updater = LocalSyncStateUpdater(store: records, queue: queue, appliers: appliers, gateway: gateway)
        dispatcher = SyncDispatcher(queue: queue, gateway: gateway, network: network,
                                    resolver: PolicyConflictResolver.fitCoach, observer: updater)
        trigger.bind(dispatcher)

        logs = MergedWorkoutLogRepository(own: WorkoutLogRepositoryImpl(store: logStore), coached: WorkoutLogRepositoryImpl(store: coachedLogStore))
        plans = WorkoutPlanRepositoryImpl(store: planStore)
        checkIns = CheckInRepositoryImpl(store: checkInStore)
        bodyComposition = BodyCompositionRepositoryImpl(store: bodyStore)
        posts = PostRepositoryImpl(store: postStore)
        sharedPhotos = SharedPhotoRepositoryImpl(store: photoStore)
        trainerProfiles = TrainerProfileRepositoryImpl(store: trainerProfileStore)
        externalActivities = ExternalActivityRepositoryImpl(store: activityStore)
        integrationLinks = IntegrationLinkRepositoryImpl(store: linkStore)
        sharingPreferences = SharingPreferencesRepositoryImpl(store: prefsStore)
        nicknames = NicknameRepositoryImpl(store: nicknameStore)
        self.records = records

        // Integrations. Spotify: public client id + PKCE, tokens in the Keychain. Strava + Google Places: through our Cloud
        // Functions only (the client secret / API key never leave the server). Demo and UI-test builds never touch the network.
        spotifyTokens = isProduction ? config.spotifyClientID.map { SpotifyTokenStore(clientID: $0, secrets: secrets) } : nil
        if isProduction, let base = config.backendBaseURL {
            let credentials = FirebaseBackendCredentials()
            backend = IntegrationBackendClient(baseURL: base, credentials: credentials)
            gymLocator = PlacesProxyGymLocator(endpoint: base.appendingPathComponent("searchGyms"), credentials: credentials)
        } else {
            backend = nil
            gymLocator = MapKitGymLocator()
        }

        // Students: the trainer registers (CPF + name), the student does the first access. Production talks to Cloud Functions; demo
        // and UI-test builds use an in-memory directory so the whole flow runs offline.
        if isProduction, let base = config.backendBaseURL {
            let client = BackendRegistrationClient(baseURL: base, trainerCredentials: FirebaseBackendCredentials(),
                                                   anonymousCredentials: FirebaseAppCheckCredentials(),
                                                   reader: StudentRegistrationReader(store: registrationStore))
            registering = client
            firstAccess = FirebaseFirstAccessService(client: client)
            passwordReset = client
            loginAliasing = client
            registrationDirectory = nil
        } else if isProduction {
            registering = UnconfiguredRegistering()
            firstAccess = UnconfiguredFirstAccess()
            passwordReset = UnconfiguredPasswordReset()
            loginAliasing = nil
            registrationDirectory = nil
        } else {
            let directory = RegistrationDirectory(trainerNames: ["ui-trainer": "Personal Demo"])
            registering = directory
            firstAccess = directory
            passwordReset = directory
            loginAliasing = nil
            registrationDirectory = directory
        }

        // Exercise catalogue: demo video, muscles, substitutes. wger.de (open, CC-BY-SA) with an on-device cache so it keeps
        // working offline once seen; UI tests swap in a deterministic stub.
        let remoteCatalog: any RemoteExerciseAPI = ProcessInfo.processInfo.arguments.contains("-UITestStubCatalog")
            ? StubExerciseAPI() : WgerExerciseAPI()
        catalog = CachedExerciseCatalogRepository(remote: remoteCatalog, store: records)

        feedback = SystemFeedback()
        notifier = UserNotificationScheduler()

        // Arrival sources are *registered* here and built per user settings (Factory pattern).
        var factory = GymArrivalProviderFactory()
        factory.register(.simulated) { SimulatedGymArrivalProvider() }
        arrivalFactory = factory     // `.geofence` is registered once the student has picked their gym(s)

        backgroundTasks = BackgroundTasks(dispatcher: dispatcher) { [weak self] in
            guard let self, let uid = await self.userID else { return }
            await ReminderRefresher(studentID: uid, plans: self.plans, logs: self.logs, notifier: self.notifier).refresh()
            await self.evaluatePresence()          // a visit may have crossed the minimum stay while the app was asleep
        }

        mediaPolicy.dataSaverEnabled = UserDefaults.standard.bool(forKey: Self.dataSaverKey)
        mediaObserver = MediaEnvironmentObserver(policy: mediaPolicy, forceCellular: ProcessInfo.processInfo.arguments.contains("-UITestCellular"))
        mediaObserver?.start()

        switch environment {
        case .production:
            session = FirebaseSession(onSignedIn: { [weak self] uid, role, name in await self?.signedIn(uid, role, name) },
                                      onSignedOut: { [weak self] in await self?.signedOut() })
        case .uiTesting:
            Task { await self.seedUITestData() }
        }
    }

    // MARK: Lifecycle

    func signedIn(_ uid: UserID, _ role: UserRole, _ name: String? = nil) async {
        userID = uid
        self.role = role
        displayName = name ?? ""
        await loadProfilePhoto()
        await dispatcher.start()
        let inbound = FirestoreInboundListener()
        inbound.start(userID: uid, role: role, appliers: appliers)
        self.inbound = inbound
        if role == .trainer { await publishTrainerProfile() }
        if role == .student, let trainerID = await session?.trainerID(uid: uid) {
            inbound.watchTrainerProfile(trainerID: trainerID.rawValue, appliers: appliers)       // name, photo and CREF the trainer shows
        }
        if role == .student {
            _ = try? await notifier.requestAuthorization()
            await ReminderRefresher(studentID: uid, plans: plans, logs: logs, notifier: notifier).refresh()
            let coordinator = GymArrivalCoordinator(studentID: uid, deviceID: deviceID, checkIns: checkIns, plans: plans,
                                                    logs: logs, notifier: notifier)
            arrival = coordinator
            presence = makePresenceCoordinator(uid)
            await restartGymMonitoring()
            await evaluatePresence()
        }
    }

    /// Sign-out wipes local data by **crypto-shredding**: destroy the master key (everything sealed becomes
    /// unreadable) and delete the rows. Unsynced edits are lost, so the UI must warn when `SyncStatus.pending > 0`.
    func signedOut() async {
        inbound?.stop()
        presenceTask?.cancel()
        await geofence?.stopMonitoring()
        geofence = nil
        presence = nil
        await arrival?.stopConsuming()
        await dispatcher.stop()
        try? keyProvider.destroyKeys()
        try? persistence.deleteAllData()
        userID = nil
        role = nil
        displayName = ""
        profilePhoto = nil
        trainerCREF = nil
    }

    // MARK: Account

    /// CPF → student / CREF → trainer, verified by the backend. Production resolves the identifier to an opaque login name with our
    /// backend and lets Firebase Auth check the password; demo builds use the in-memory directory.
    var authentication: any AuthenticationService {
        if environment == .production {
            return loginAliasing.map { FirebaseAuthenticationService(aliasing: $0) } ?? UnconfiguredAuthenticationService()
        }
        return DemoAuthenticationService(directory: registrationDirectory)
    }

    /// Called with the server-verified user once sign-in succeeds (the Firebase listener may have routed the app already).
    func completeSignIn(_ user: SignedInUser) async {
        if environment == .production {
            if userID != user.userID { await signedIn(user.userID, user.role, user.displayName) }
            if user.role == .trainer { await publishTrainerProfile(cref: user.cref) }
            return
        }
        userID = user.userID
        role = user.role
        displayName = user.displayName
        await loadProfilePhoto()
        if user.role == .trainer { await publishTrainerProfile(cref: user.cref) }
    }

    // MARK: What students see of their trainer

    /// Creates the trainer's public profile on first sign-in (name, the CREF they signed in with, their photo) and keeps it current.
    /// The CREF typed at sign-in fills a blank one; it never overwrites a CREF the trainer chose to show.
    func publishTrainerProfile(cref: String? = nil) async {
        guard role == .trainer, let uid = userID else { return }
        let photo = profilePhoto.flatMap { ProfilePhoto.process($0, maxSide: 400, quality: 0.7) }
        let publish = PublishTrainerProfileUseCase(repository: trainerProfiles, deviceID: deviceID)
        if let saved = try? await publish.execute(trainerID: uid, displayName: displayName, edit: { profile in
            if profile.cref == nil, let cref { profile.cref = cref }
            if profile.photo == nil, let photo { profile.photo = photo }
        }) {
            trainerCREF = saved.cref
        }
    }

    func updateTrainerCREF(_ cref: String?) async -> Bool {
        guard role == .trainer, let uid = userID else { return false }
        let publish = PublishTrainerProfileUseCase(repository: trainerProfiles, deviceID: deviceID)
        guard let saved = try? await publish.execute(trainerID: uid, displayName: displayName, edit: { $0.cref = cref }) else { return false }
        trainerCREF = saved.cref
        return true
    }

    private func publishTrainerPhoto(_ photo: Data?) async {
        guard role == .trainer, let uid = userID else { return }
        let small = photo.flatMap { ProfilePhoto.process($0, maxSide: 400, quality: 0.7) }
        _ = try? await PublishTrainerProfileUseCase(repository: trainerProfiles, deviceID: deviceID)
            .execute(trainerID: uid, displayName: displayName, edit: { $0.photo = small })
    }

    /// The trainer a student belongs to (production reads it from the student's own account document; demo from the directory).
    func studentTrainerID() async -> UserID? {
        guard let uid = userID else { return nil }
        if environment == .production { return await session?.trainerID(uid: uid) }
        return await registrationDirectory?.registration(forStudent: uid)?.trainerID
    }

    func makeStudentTrainerModel() async -> StudentTrainerViewModel? {
        guard let trainerID = await studentTrainerID() else { return nil }
        return StudentTrainerViewModel(trainerID: trainerID, repository: trainerProfiles)
    }

    // MARK: Profile & settings

    private static let dataSaverKey = "dataSaver.enabled"

    func setDataSaver(_ enabled: Bool) {
        mediaPolicy.dataSaverEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.dataSaverKey)
    }

    func loadProfilePhoto() async {
        guard let uid = userID else { profilePhoto = nil; return }
        profilePhoto = (try? await records.record(collection: "profile", id: "photo-\(uid)"))?.payload
    }

    /// Stores a downsized copy of the picked photo (or removes it) and returns what is now stored.
    func setProfilePhoto(_ data: Data?) async -> Data? {
        guard let uid = userID else { return nil }
        guard let data, let processed = ProfilePhoto.process(data) else {
            if data == nil { try? await records.remove(collection: "profile", id: "photo-\(uid)"); profilePhoto = nil; await publishTrainerPhoto(nil) }
            return profilePhoto
        }
        try? await records.upsert(LocalRecord(collection: "profile", id: "photo-\(uid)", ownerID: uid.rawValue, sortDate: Date(), syncState: .synced,
                                              localVersion: 0, remoteVersion: 0, payload: processed))
        profilePhoto = processed
        await publishTrainerPhoto(processed)
        return processed
    }

    /// Height, weight and age the student gave at first access. Production reads them from the student's own account document
    /// (the registration is the trainer's to read); demo builds from the in-memory directory.
    func studentBodyProfile() async -> BodyProfile {
        guard let uid = userID else { return BodyProfile() }
        if environment == .production { return await session?.bodyProfile(uid: uid) ?? BodyProfile() }
        return await registrationDirectory?.registration(forStudent: uid).map(BodyProfile.init) ?? BodyProfile()
    }

    /// The student's read-only body screen (weight, height, BMI, and the trainer's measurements).
    func makeStudentBodyModel() async -> StudentBodyViewModel {
        let model = StudentBodyViewModel(profile: await studentBodyProfile(), studentID: userID ?? "unknown", repository: bodyComposition)
        await model.load()
        return model
    }

    func makeProfileModel() -> ProfileViewModel {
        ProfileViewModel(name: displayName, role: role ?? .student, photo: profilePhoto, dataSaverEnabled: mediaPolicy.dataSaverEnabled,
                         cref: trainerCREF,
                         pendingChanges: { [weak self] in await self?.pendingChangeCount() ?? 0 },
                         signOut: { [weak self] in await self?.signOut() },
                         savePhoto: { [weak self] data in await self?.setProfilePhoto(data) },
                         saveDataSaver: { [weak self] on in self?.setDataSaver(on) },
                         saveCREF: role == .trainer ? { [weak self] cref in await self?.updateTrainerCREF(cref) ?? false } : nil)
    }

    /// Unsent edits (queued + in flight + failed): signing out shreds the local copy, so the profile warns when this is > 0.
    func pendingChangeCount() async -> Int {
        let counts = await queue.counts()
        return counts.pending + counts.inFlight + counts.failed
    }

    func signOut() async {
        if environment == .production {
            try? session?.signOut()          // the auth listener then runs `signedOut()` (crypto-shred + sign-in screen)
        } else {
            userID = nil
            role = nil
            displayName = ""
        }
    }

    // MARK: Gym detection → automatic workout start

    private static let gymDetectionKey = "gymDetection.enabled"

    /// A device-local switch (UserDefaults is fine: it holds no health or location data, just on/off).
    var gymDetectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.gymDetectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.gymDetectionKey) }
    }

    func selectedGyms() -> SelectedGymsStore? { userID.map { SelectedGymsStore(local: records, owner: $0) } }
    func trackPlays() -> TrackPlayRepositoryImpl? { userID.map { TrackPlayRepositoryImpl(local: records, owner: $0) } }

    private func makePresenceCoordinator(_ uid: UserID) -> GymPresenceCoordinator {
        GymPresenceCoordinator(studentID: uid, deviceID: deviceID, store: PendingVisitStoreImpl(local: records, owner: uid),
                               plans: plans, logs: logs, checkIns: checkIns, notifier: notifier)
    }

    /// (Re)builds the geofence from the student's chosen gyms. Called after sign-in and whenever the gym or the switch changes.
    func restartGymMonitoring() async {
        guard role == .student, let coordinator = arrival else { return }
        await coordinator.stopConsuming()
        presenceTask?.cancel()
        await geofence?.stopMonitoring()
        geofence = nil
        guard gymDetectionEnabled, let venues = await selectedGyms()?.load(), !venues.isEmpty else { return }

        let detector = GeofenceDetector(venues: venues)
        try? await detector.startMonitoring()
        geofence = detector
        await coordinator.startConsuming(detector)
        consumePresence(detector.presenceEvents())
    }

    private func consumePresence(_ events: AsyncStream<GymPresenceEvent>) {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handlePresence(event)
            }
        }
    }

    private func handlePresence(_ event: GymPresenceEvent) async {
        guard let presence else { return }
        let outcome = try? await presence.handle(event)
        await evaluatePresence()
        // While the app happens to be alive, also wake up exactly when the minimum stay is reached. (If it isn't alive, the
        // local notification scheduled by the coordinator and the next launch / background refresh cover it.)
        if case .dwellStarted(let readyAt)? = outcome, readyAt > Date() {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(readyAt.timeIntervalSinceNow, 0) * 1_000_000_000) + 1_000_000_000)
                await self?.evaluatePresence()
            }
        }
    }

    /// Decides every open gym visit. Safe to call any time: on foreground, from a background refresh, after an event.
    func evaluatePresence() async {
        _ = try? await presence?.evaluate()
    }

    func makeGymPickerModel() -> GymPickerViewModel {
        GymPickerViewModel(locator: gymLocator,
                           currentLocation: { try await CurrentLocation().once() },
                           onSelect: { [weak self] venue in
            guard let self, let store = self.selectedGyms() else { throw ConnectionFailure.notConfigured }
            try await store.add(venue)
            self.gymDetectionEnabled = true                  // choosing a gym is the intent to use it
            await self.restartGymMonitoring()
        })
    }

    // MARK: Feed

    /// After a workout: build the shareable card (with the songs that were playing, if the student allows it).
    func publishPost(for log: WorkoutLog) async {
        guard let uid = userID, let plays = trackPlays() else { return }
        let includeMusic = (try? await sharingPreferences.preferences(studentID: uid).includeMusicInPosts) ?? false
        let music: SpotifyHistoryClient? = spotifyTokens.map { SpotifyHistoryClient(tokens: $0) }
        _ = try? await PublishWorkoutPostUseCase(logs: logs, posts: posts, plays: plays, music: music)
            .execute(log: log, deviceID: deviceID, includeMusic: includeMusic)
    }

    /// Imports today's listening history and refreshes "Playlist of the day". Opt-in, and a no-op when Spotify isn't connected.
    func syncListening() async {
        guard let uid = userID, let tokens = spotifyTokens, let plays = trackPlays() else { return }
        let includeMusic = (try? await sharingPreferences.preferences(studentID: uid).includeMusicInPosts) ?? false
        _ = try? await SyncListeningUseCase(music: SpotifyHistoryClient(tokens: tokens), plays: plays, posts: posts)
            .execute(studentID: uid, deviceID: deviceID, includeMusic: includeMusic)
    }

    func handle(deepLink url: URL) {
        guard url.scheme == "fitcoach", url.host == "workout", url.path == "/start",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "checkIn" })?.value else { return }
        pendingCheckInID = CheckInID(id)
    }

    // MARK: UI-test support

    private func seedUITestData() async {
        let student: UserID = "ui-student"
        let asTrainer = ProcessInfo.processInfo.arguments.contains("-UITestTrainer")      // open straight into the personal trainer's area
        if !asTrainer { userID = student; role = .student; displayName = "Aluno Demo" }   // (the trainer is signed in after the data exists)
        // Real wger exercises (they have demo videos). Names are what the trainer typed, in Portuguese.
        func strength(_ id: String, _ wger: Int, _ name: String, sets: Int, reps: ClosedRange<Int>, kg: Double, rest: Int) -> WorkoutBlock {
            .resistance(ResistanceBlock(id: BlockID(id), exercise: ExerciseRef(id: ExerciseID("wger-\(wger)"), name: name),
                                        sets: (1...sets).map { PrescribedSet(index: $0, repsMin: reps.lowerBound, repsMax: reps.upperBound, targetLoadKg: kg) },
                                        restSeconds: rest))
        }
        func demoDay(_ id: String, _ label: String, order: Int, _ blocks: [WorkoutBlock]) -> WorkoutTemplate {
            WorkoutTemplate(id: TemplateID(id), label: label, order: order, blocks: blocks)
        }
        func plain(_ id: String, _ name: String, sets: Int = 3, kg: Double) -> WorkoutBlock {
            .resistance(ResistanceBlock(id: BlockID(id), exercise: ExerciseRef(id: ExerciseID("demo-\(id)"), name: name),
                                        sets: (1...sets).map { PrescribedSet(index: $0, repsMin: 8, repsMax: 12, targetLoadKg: kg) }, restSeconds: 60))
        }
        // A 4-day split (A–D): the sequence — not the weekday — decides what is next.
        let templates = [
            demoDay("tpl-a", "Treino A · Peito e tríceps", order: 0, [
                strength("blk-bench", 73, "Supino reto", sets: 3, reps: 8...12, kg: 40, rest: 90),
                strength("blk-incline", 538, "Supino inclinado com barra", sets: 3, reps: 8...12, kg: 30, rest: 90),
                strength("blk-skull", 246, "Tríceps testa com barra EZ", sets: 3, reps: 10...12, kg: 20, rest: 60),
                .hiit(HIITBlock(id: "hiit", title: "Finalizador", rounds: 4, workSeconds: 20, restSeconds: 10, movements: ["Burpee", "Polichinelo"])),
            ]),
            demoDay("tpl-b", "Treino B · Costas e bíceps", order: 1, [plain("b-row", "Remada curvada", kg: 35), plain("b-pulldown", "Puxada frontal", kg: 45), plain("b-curl", "Rosca direta", kg: 15)]),
            demoDay("tpl-c", "Treino C · Pernas", order: 2, [plain("c-squat", "Agachamento livre", kg: 60), plain("c-leg-press", "Leg press 45°", kg: 120), plain("c-calf", "Panturrilha em pé", kg: 50)]),
            demoDay("tpl-d", "Treino D · Ombros e core", order: 3, [plain("d-press", "Desenvolvimento com halteres", kg: 16), plain("d-lateral", "Elevação lateral", kg: 8), plain("d-plank", "Prancha com carga", sets: 3, kg: 10)]),
        ]
        let now = Date()
        // `-UITestFocusDemo`: a plan with 2 strength + 2 volume weeks, and today falls in a VOLUME week — so the bench press (planned at
        // 40 kg) is heavier than the 35 kg the student lifted in their strength weeks, and the warning shows.
        let focusDemo = ProcessInfo.processInfo.arguments.contains("-UITestFocusDemo")
        let plan = WorkoutPlan(id: "ui-plan", trainerID: "ui-trainer", studentID: student, name: "Hipertrofia · 12 semanas", templates: templates,
                               focusCycle: focusDemo ? FocusCycle(strengthWeeks: 2, volumeWeeks: 2) : nil,
                               targetSessionsPerWeek: 3, startDate: focusDemo ? now.addingTimeInterval(-15 * 86_400) : now,
                               meta: SyncMetadata(updatedAt: now, lastWriterDeviceID: deviceID))
        _ = try? await planStore.save(plan)

        // The personal trainer's roster: "Aluno Demo" is already active, with a few weeks of bench-press history so the progress charts
        // have something to draw (strength weeks heavy/few reps/long rest, volume weeks light/many reps/short rest).
        try? await registrationDirectory?.seedActive(cpf: "390.533.447-05", fullName: "Aluno Demo", trainerID: "ui-trainer", studentID: student,
                                                     email: "aluno@demo.app", age: 29, gender: .male, heightCm: 178, weightKg: 82, password: "demo123")
        func session(weeksAgo: Int = 0, daysAgo: Double = 1, template: (id: String, label: String) = ("tpl-d", "Treino D · Ombros e core"),
                     kg: Double, reps: Int, rest: Int, focus: TrainingFocus) -> WorkoutLog {
            let day = now.addingTimeInterval(-Double(weeksAgo) * 7 * 86_400 - daysAgo * 86_400)
            let sets = (1...3).map { SetLog(index: $0, weightKg: kg, reps: reps, restTakenSeconds: $0 == 1 ? nil : rest, completedAt: day.addingTimeInterval(Double($0) * 240)) }
            return WorkoutLog(planID: "ui-plan", templateID: TemplateID(template.id), templateLabel: template.label, studentID: student, status: .completed,
                              startedAt: day, completedAt: day.addingTimeInterval(3_000), rotationIndex: 0, focus: focus,
                              blocks: [.resistance(ResistanceLog(blockID: "blk-bench", exercise: ExerciseRef(id: "wger-73", name: "Supino reto"), sets: sets))],
                              sessionRPE: 7, meta: SyncMetadata(updatedAt: day, lastWriterDeviceID: deviceID))
        }
        for history in [session(weeksAgo: 6, kg: 30, reps: 5, rest: 150, focus: .strength), session(weeksAgo: 5, kg: 32.5, reps: 5, rest: 150, focus: .strength),
                        session(weeksAgo: 4, kg: 25, reps: 12, rest: 60, focus: .volume), session(weeksAgo: 3, kg: 25, reps: 12, rest: 60, focus: .volume),
                        session(weeksAgo: 2, kg: 35, reps: 4, rest: 180, focus: .strength),
                        // This month, so the History calendar has marks. The most recent one is a "Treino D", so today's workout stays "Treino A".
                        session(daysAgo: 4, template: ("tpl-c", "Treino C · Pernas"), kg: 35, reps: 4, rest: 180, focus: .strength),
                        session(daysAgo: 1, kg: 25, reps: 12, rest: 60, focus: .volume)] {
            _ = try? await logStore.save(history)
        }

        // What the student sees of their trainer: name, CREF and a photo.
        _ = try? await trainerProfiles.save(TrainerProfile(id: "ui-trainer", displayName: "Personal Demo", cref: "012345-G/AL", photo: ProfilePhoto.demoPhoto(),
                                                           meta: SyncMetadata(updatedAt: now, lastWriterDeviceID: deviceID)))
        if asTrainer { trainerCREF = "012345-G/AL" }

        // Feed: two cards so the tab has something to show (one with the song that was playing at a PR).
        let meta = SyncMetadata(updatedAt: now, lastWriterDeviceID: deviceID)
        _ = try? await posts.save(ActivityPost(
            id: "seed-pr", studentID: student, kind: .personalRecord, createdAt: now.addingTimeInterval(-86_400),
            title: String(localized: "New PR · \("Supino reto")"), subtitle: "85 kg × 5",
            stats: [PostStat(label: String(localized: "Est. 1RM"), value: "99 kg"), PostStat(label: String(localized: "Sets"), value: "12")],
            tracks: [PostTrack(title: "Eye of the Tiger", artist: "Survivor", plays: 3, note: String(localized: "Playing when you hit it"))], meta: meta))
        _ = try? await posts.save(ActivityPost(
            id: "seed-photo", studentID: student, kind: .workout, createdAt: now.addingTimeInterval(-3 * 86_400), title: "Treino C · Pernas",
            stats: [PostStat(label: String(localized: "Time"), value: String(localized: "\(48) min")), PostStat(label: String(localized: "Sets"), value: "15")],
            photo: ProfilePhoto.demoPhoto(), meta: meta))
        if let demoPhoto = ProfilePhoto.demoPhoto() {
            _ = try? await sharedPhotos.save(SharedPhoto(id: "seed-photo", studentID: student, takenAt: now.addingTimeInterval(-3 * 86_400),
                                                         caption: "Treino C · Pernas", photo: demoPhoto, meta: meta))
        }
        _ = try? await posts.save(ActivityPost(
            id: "seed-playlist", studentID: student, kind: .playlistOfTheDay, createdAt: now.addingTimeInterval(-172_800),
            title: String(localized: "Playlist of the day"),
            tracks: [PostTrack(title: "Stronger", artist: "Kanye West", plays: 2), PostTrack(title: "Lose Yourself", artist: "Eminem", plays: 1)], meta: meta))

        // `-UITestAutoStart`: the student walked into the gym 31 minutes ago and is still there → the workout starts by itself.
        if ProcessInfo.processInfo.arguments.contains("-UITestAutoStart") {
            let provider = SimulatedGymPresenceProvider()
            simulatedPresence = provider
            presence = makePresenceCoordinator(student)
            consumePresence(provider.presenceEvents())
            try? await provider.startMonitoring()
            provider.simulate(.entered, venue: GymVenue(id: "ui-gym", name: "Smart Fit Centro", latitude: -9.66, longitude: -35.73),
                              at: now.addingTimeInterval(-31 * 60))
        }
        if asTrainer { userID = "ui-trainer"; role = .trainer; displayName = "Personal Demo" }
        await dispatcher.start()
    }
}

/// Demo sign-in. A CPF registered through the app needs the password chosen at first access; the seeded "Aluno Demo" and any other CPF
/// get the generic demo student; a CREF opens the personal trainer's area. Any non-empty password works for the generic ones.
struct DemoAuthenticationService: AuthenticationService {
    let directory: RegistrationDirectory?

    func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser {
        guard !password.isEmpty else { throw AuthenticationError.invalidCredentials }
        switch credential {
        case .cpf(let digits):
            if let directory, let user = try await directory.signIn(cpf: digits, password: password) { return user }
            return SignedInUser(userID: "ui-student", role: .student, displayName: "Aluno Demo")
        case .cref(let registration): return SignedInUser(userID: "ui-trainer", role: .trainer, displayName: "Personal Demo", cref: registration)
        case .unknown: throw AuthenticationError.invalidCredentials
        }
    }
}

struct UnconfiguredAuthenticationService: AuthenticationService {
    func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser { throw AuthenticationError.notConfigured }
}

/// UI-test "server": accepts everything, tracks `_rev` per document so conflicts behave like the real thing.
actor LoopbackGateway: RemoteGateway {
    private var revisions: [DocumentPath: Int] = [:]

    func apply(_ mutation: Mutation) async throws -> RemoteApplyResult {
        let current = revisions[mutation.path] ?? 0
        if let base = mutation.baseVersion, base != current { throw RemoteError.conflict(serverVersion: current) }
        revisions[mutation.path] = current + 1
        return RemoteApplyResult(version: current + 1)
    }

    func fetch(_ path: DocumentPath) async throws -> RemoteDocument? { nil }
}
