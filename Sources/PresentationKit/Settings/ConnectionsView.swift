import Domain
import SwiftUI

public struct ConnectionsView: View {
    private let model: ConnectionsViewModel
    private let gymPicker: () -> AnyView
    @Environment(\.dismiss) private var dismiss
    @State private var pickingGym = false

    /// - Parameter gymPicker: builds the "choose your gym" screen (CoreLocation/MapKit live in the app target).
    public init(model: ConnectionsViewModel, gymPicker: @escaping () -> AnyView) {
        self.model = model
        self.gymPicker = gymPicker
    }

    public var body: some View {
        NavigationStack {
            List {
                gymSection
                musicSection
                stravaSection
                if let message = model.errorMessage, !message.isEmpty {
                    Section { Text(verbatim: message).foregroundStyle(.red).accessibilityIdentifier("connections-error") }
                }
            }
            .navigationTitle(String(localized: "Connections"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .task { await model.run() }
            .sheet(isPresented: $pickingGym, onDismiss: { Task { await model.refresh() } }) { gymPicker() }
        }
    }

    private var gymSection: some View {
        Section {
            Button {
                pickingGym = true
            } label: {
                HStack {
                    Text(String(localized: "My gym"))
                    Spacer()
                    Text(verbatim: model.status.gymName ?? String(localized: "Choose")).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("choose-gym")
            Toggle(isOn: Binding(get: { model.status.gymDetectionOn }, set: { on in Task { await model.setGymDetection(on) } })) {
                Text(String(localized: "Start workouts automatically"))
            }
            .disabled(model.busy == .gym || model.status.gymName == nil)
            .accessibilityIdentifier("toggle-gym-detection")
        } header: { Text(String(localized: "Gym")) } footer: {
            Text(String(localized: "When you stay at your gym for 30 minutes, today's workout starts on its own. Your location stays on this phone."))
        }
    }

    private var musicSection: some View {
        Section {
            if model.status.spotifyAvailable {
                if model.status.spotifyConnected {
                    Toggle(String(localized: "Show songs in my posts"),
                           isOn: Binding(get: { model.preferences.includeMusicInPosts }, set: { on in Task { await model.setIncludeMusic(on) } }))
                        .accessibilityIdentifier("toggle-music-in-posts")
                    Button(String(localized: "Disconnect Spotify"), role: .destructive) { Task { await model.disconnectSpotify() } }
                } else {
                    Button(String(localized: "Connect Spotify")) { Task { await model.connectSpotify() } }
                        .disabled(model.busy == .spotify)
                        .accessibilityIdentifier("connect-spotify")
                }
            } else {
                Text(String(localized: "Not set up in this build")).foregroundStyle(.secondary)
            }
        } header: { Text(String(localized: "Music")) } footer: {
            Text(String(localized: "Only song names, artists and how many times you played them. Nothing else from your account."))
        }
    }

    private var stravaSection: some View {
        Section {
            if model.status.stravaAvailable {
                if model.stravaConnected {
                    Toggle(String(localized: "Share with my trainer"),
                           isOn: Binding(get: { model.preferences.shareStravaWithTrainer }, set: { on in Task { await model.setShareStravaWithTrainer(on) } }))
                        .accessibilityIdentifier("toggle-share-strava")
                    Button(String(localized: "Disconnect Strava"), role: .destructive) { Task { await model.disconnectStrava() } }
                } else {
                    Button(String(localized: "Connect Strava")) { Task { await model.connectStrava() } }
                        .disabled(model.busy == .strava)
                        .accessibilityIdentifier("connect-strava")
                }
            } else {
                Text(String(localized: "Not set up in this build")).foregroundStyle(.secondary)
            }
        } header: { Text("Strava") } footer: {
            Text(String(localized: "Activities you finish on Strava appear in your feed. Disconnecting deletes the copies we stored."))
        }
    }
}
