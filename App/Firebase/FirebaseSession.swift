import DataKit
import Domain
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import SyncKit

// NOT COMPILED IN THE AUTHORING ENVIRONMENT — see README → "Verification status".

enum FirebaseBootstrap {
    /// Call once, first thing in `application(_:didFinishLaunchingWithOptions:)`.
    static func configure() {
        // App Check (App Attest in release, debug provider in DEBUG): Firestore and Cloud Functions then
        // reject requests that don't come from a genuine build of this app (OWASP M3/M7 mitigation).
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestFactory())
        #endif
        FirebaseApp.configure()

        let settings = FirestoreSettings()
        // Memory-only cache: pending writes live in OUR queue, not in a second hidden disk queue.
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings
    }
}

private final class AppAttestFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? { AppAttestProvider(app: app) }
}

/// Auth state → who is signed in and in which role. The role is read from `users/{uid}` and is only used to
/// choose a UI shell: **authorisation never depends on it** — Firestore rules check `trainerLinks` instead.
@MainActor
@Observable
final class FirebaseSession {
    private(set) var userID: UserID?
    private(set) var role: UserRole?
    private(set) var isLoading = true

    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private let onSignedIn: @MainActor (UserID, UserRole, String?) async -> Void
    @ObservationIgnored private let onSignedOut: @MainActor () async -> Void

    init(onSignedIn: @escaping @MainActor (UserID, UserRole, String?) async -> Void,
         onSignedOut: @escaping @MainActor () async -> Void) {
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in await self?.authChanged(user) }
        }
    }

    private func authChanged(_ user: User?) async {
        defer { isLoading = false }
        guard let user else {
            userID = nil
            role = nil
            await onSignedOut()
            return
        }
        let uid = UserID(user.uid)
        do {
            let snapshot = try await Firestore.firestore().collection("users").document(user.uid).getDocument()
            guard let raw = snapshot.data()?["role"] as? String, let resolved = UserRole(rawValue: raw) else { return }
            userID = uid
            role = resolved
            await onSignedIn(uid, resolved, (snapshot.data()?["displayName"] as? String) ?? user.displayName)
        } catch {
            // Offline at launch: keep whatever role we cached last time (stored in the Keychain by AppContainer).
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    /// The trainer a student is linked to (set server-side when the account was created).
    func trainerID(uid: UserID) async -> UserID? {
        guard let raw = try? await Firestore.firestore().collection("users").document(uid.rawValue).getDocument().data()?["trainerID"] as? String else { return nil }
        return UserID(raw)
    }

    /// Height, weight and age as given at first access — the Cloud Function copies them into the student's own `users/{uid}` document
    /// (the registration itself is readable only by the trainer).
    func bodyProfile(uid: UserID) async -> BodyProfile? {
        guard let data = try? await Firestore.firestore().collection("users").document(uid.rawValue).getDocument().data() else { return nil }
        return BodyProfile(heightCm: (data["heightCm"] as? NSNumber)?.doubleValue, weightKg: (data["weightKg"] as? NSNumber)?.doubleValue,
                           age: (data["age"] as? NSNumber)?.intValue)
    }
}

/// Real-time inbound sync: Firestore snapshot listeners → `applyRemote` on the matching offline-first store.
/// Never overwrites a queued local edit (`OfflineFirstStore.applyRemote` guards that).
final class FirestoreInboundListener {
    private let database: Firestore
    private var registrations: [ListenerRegistration] = []
    private var perStudent: [String: [ListenerRegistration]] = [:]

    init(database: Firestore = .firestore()) {
        self.database = database
    }

    func start(userID: UserID, role: UserRole, appliers: [String: any RemoteDocumentApplying]) {
        stop()
        switch role {
        case .student:
            listen(database.collection("plans").whereField("studentID", isEqualTo: userID.rawValue), into: appliers["plans"])
            watchStudentData(studentID: userID.rawValue, role: .student, appliers: appliers)
        case .trainer:
            listen(database.collection("plans").whereField("trainerID", isEqualTo: userID.rawValue), into: appliers["plans"])
            // The trainer's students (written by Cloud Functions) and their own private nicknames (nobody else can read those).
            listen(database.collection("registrations").whereField("trainerID", isEqualTo: userID.rawValue), into: appliers["registrations"])
            listen(database.collection("trainers").document(userID.rawValue).collection("nicknames"), into: appliers["nicknames"])
            // The roster comes from server-managed link documents; attach per-student listeners as links appear.
            let links = database.collection("trainerLinks")
                .whereField("trainerID", isEqualTo: userID.rawValue)
                .whereField("status", isEqualTo: "active")
            registrations.append(links.addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot else { return }
                for change in snapshot.documentChanges {
                    guard let studentID = change.document.data()["studentID"] as? String else { continue }
                    switch change.type {
                    case .added: self.watchStudentData(studentID: studentID, role: .trainer, appliers: appliers)
                    case .removed: self.perStudent.removeValue(forKey: studentID)?.forEach { $0.remove() }
                    case .modified: break
                    }
                }
            })
        }
    }

    /// A student's view of their trainer: the one `trainerProfiles/{trainerId}` document (name, photo, CREF). The rules let a student read exactly
    /// the document of the trainer they are linked to.
    func watchTrainerProfile(trainerID: String, appliers: [String: any RemoteDocumentApplying]) {
        guard perStudent["trainer-\(trainerID)"] == nil else { return }
        let query = database.collection("trainerProfiles").whereField(FieldPath.documentID(), isEqualTo: trainerID)
        perStudent["trainer-\(trainerID)"] = [listen(query, into: appliers["trainerProfiles"])].compactMap { $0 }
    }

    func stop() {
        registrations.forEach { $0.remove() }
        perStudent.values.flatMap { $0 }.forEach { $0.remove() }
        registrations.removeAll()
        perStudent.removeAll()
    }

    private func watchStudentData(studentID: String, role: UserRole, appliers: [String: any RemoteDocumentApplying]) {
        guard perStudent[studentID] == nil else { return }
        let root = database.collection("students").document(studentID)
        var registrations = [
            listen(root.collection("workoutLogs"), into: appliers["workoutLogs"]),
            // Workouts the trainer ran next to the student: the trainer's own writes come back here, and the student's phone receives them.
            listen(root.collection("coachedLogs"), into: appliers["coachedLogs"]),
            listen(root.collection("bodyCheckpoints"), into: appliers["bodyCheckpoints"]),
            // Photos the student attached to a card. Cards stay private; these pictures are what the trainer is allowed to see.
            listen(root.collection("sharedPhotos"), into: appliers["sharedPhotos"]),
            listen(root.collection("checkIns"), into: appliers["checkIns"]),
            // Strava activities: the student sees their own; a trainer's listener only ever delivers once the student has shared
            // (the rules deny it otherwise — the listener then simply stays silent).
            listen(root.collection("externalActivities"), into: appliers["externalActivities"]),
        ]
        if role == .student {
            // Private to the student: cards, the proof of what is connected, and their own sharing switches.
            registrations += [
                listen(root.collection("posts"), into: appliers["posts"]),
                listen(root.collection("integrations"), into: appliers["integrations"]),
                listen(root.collection("sharing"), into: appliers["sharing"]),
            ]
        }
        perStudent[studentID] = registrations.compactMap { $0 }
    }

    @discardableResult
    private func listen(_ query: Query, into applier: (any RemoteDocumentApplying)?) -> ListenerRegistration? {
        guard let applier else { return nil }
        let registration = query.addSnapshotListener { snapshot, error in
            guard let snapshot, error == nil else { return }   // transient listener errors resume automatically
            for change in snapshot.documentChanges where change.type != .removed {   // removals are tombstones, not deletes
                let data = change.document.data()
                let document = RemoteDocument(fields: FirestoreValues.decode(data),
                                              version: data["_rev"] as? Int ?? 0,
                                              updatedAt: (data["_updatedAt"] as? Timestamp)?.dateValue())
                Task { _ = try? await applier.applyRemote(document, overwritePending: false) }
            }
        }
        registrations.append(registration)
        return registration
    }
}
