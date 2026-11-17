import Domain
import Foundation
import Observation

/// What the app can do about each connection. Implemented in the app target (CoreLocation, OAuth sessions, Keychain).
@MainActor
public protocol ConnectionsActions {
    func status() async -> ConnectionStatus
    func setGymDetection(enabled: Bool) async throws
    func connectSpotify() async throws
    func disconnectSpotify() async
    func connectStrava() async throws
    func disconnectStrava() async throws
}

public struct ConnectionStatus: Equatable, Sendable {
    public var gymDetectionOn: Bool
    public var gymName: String?
    /// A client id is configured for this build.
    public var spotifyAvailable: Bool
    public var spotifyConnected: Bool
    public var stravaAvailable: Bool

    public init(gymDetectionOn: Bool = false, gymName: String? = nil, spotifyAvailable: Bool = false,
                spotifyConnected: Bool = false, stravaAvailable: Bool = false) {
        self.gymDetectionOn = gymDetectionOn
        self.gymName = gymName
        self.spotifyAvailable = spotifyAvailable
        self.spotifyConnected = spotifyConnected
        self.stravaAvailable = stravaAvailable
    }
}

/// The "Connections" screen: gym detection, Spotify (songs only), Strava, and what is shared with whom.
/// Every switch defaults to off; every connect/disconnect is explicit and reversible.
@MainActor
@Observable
public final class ConnectionsViewModel {
    public enum Item: String, Sendable { case gym, spotify, strava }

    public private(set) var status = ConnectionStatus()
    public private(set) var preferences: SharingPreferences
    public private(set) var stravaConnected = false
    public private(set) var busy: Item?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let actions: any ConnectionsActions
    @ObservationIgnored private let preferenceStore: any SharingPreferencesRepository
    @ObservationIgnored private let links: any IntegrationLinkRepository

    public init(studentID: UserID, actions: any ConnectionsActions, preferences: any SharingPreferencesRepository,
                links: any IntegrationLinkRepository, now: Date = Date()) {
        self.studentID = studentID
        self.actions = actions
        self.preferenceStore = preferences
        self.links = links
        self.preferences = SharingPreferences(studentID: studentID, meta: SyncMetadata(updatedAt: now, lastWriterDeviceID: "", state: .synced))
    }

    public func run() async {
        status = await actions.status()
        let prefsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await value in self.preferenceStore.observePreferences(studentID: self.studentID) { self.preferences = value }
        }
        let linksTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await items in self.links.observeLinks(studentID: self.studentID) {
                self.stravaConnected = items.first { $0.provider == .strava }?.isConnected ?? false
            }
        }
        await withTaskCancellationHandler {
            await prefsTask.value
            await linksTask.value
        } onCancel: {
            prefsTask.cancel()
            linksTask.cancel()
        }
    }

    // MARK: Switches the student owns

    public func setIncludeMusic(_ on: Bool) async {
        guard on != preferences.includeMusicInPosts else { return }
        var changed = preferences
        changed.includeMusicInPosts = on
        await save(changed)
    }

    public func setShareStravaWithTrainer(_ on: Bool) async {
        guard on != preferences.shareStravaWithTrainer else { return }
        var changed = preferences
        changed.shareStravaWithTrainer = on
        await save(changed)
    }

    private func save(_ value: SharingPreferences) async {
        let previous = preferences
        preferences = value                                  // optimistic: the toggle must not lag
        do { preferences = try await preferenceStore.save(value) } catch {
            preferences = previous
            errorMessage = String(localized: "Couldn't save that change.")
        }
    }

    // MARK: Connections

    public func setGymDetection(_ on: Bool) async {
        await perform(.gym) { try await self.actions.setGymDetection(enabled: on) }
    }

    public func connectSpotify() async { await perform(.spotify) { try await self.actions.connectSpotify() } }

    public func disconnectSpotify() async {
        busy = .spotify
        await actions.disconnectSpotify()
        status = await actions.status()
        busy = nil
    }

    public func connectStrava() async { await perform(.strava) { try await self.actions.connectStrava() } }

    public func disconnectStrava() async {
        await perform(.strava) {
            try await self.actions.disconnectStrava()
            await self.setShareStravaWithTrainer(false)       // nothing left to share
        }
    }

    public func dismissError() { errorMessage = nil }

    /// Re-reads what the app says is connected (e.g. after the gym picker closed).
    public func refresh() async { status = await actions.status() }

    private func perform(_ item: Item, _ work: () async throws -> Void) async {
        busy = item
        errorMessage = nil
        do { try await work() } catch {
            let message = Self.message(for: error)
            errorMessage = message.isEmpty ? nil : message      // a cancelled sign-in sheet is not an error
        }
        status = await actions.status()
        busy = nil
    }

    static func message(for error: Error) -> String {
        if error is CancellationError { return "" }
        switch error as? ConnectionFailure {
        case .cancelled: return ""                           // the user closed the sheet: not an error
        case .permissionDenied: return String(localized: "Location access is needed. You can allow it in Settings.")
        case .notConfigured: return String(localized: "This connection isn't set up in this build.")
        case .signInFailed: return String(localized: "Couldn't connect. Please try again.")
        case nil: return String(localized: "Something went wrong. Please try again.")
        }
    }
}

/// What a connect/disconnect action can fail with, in terms the screen understands.
public enum ConnectionFailure: Error, Equatable, Sendable {
    case cancelled, permissionDenied, notConfigured, signInFailed
}
