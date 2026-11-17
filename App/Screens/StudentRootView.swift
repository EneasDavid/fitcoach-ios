import Domain
import PresentationKit
import SwiftUI

/// The student's shell: **Today** (start training) and **Feed** (cards you can share). The student's photo sits at the top-left of
/// both tabs, always; tapping it opens settings (profile, reduce motion & data, connections, log out).
struct StudentRootView: View {
    private enum Tab: Hashable { case today, history, feed }

    let container: AppContainer
    @State private var home: StudentHomeViewModel
    @State private var history: HistoryViewModel
    @State private var feed: FeedViewModel
    @State private var tab: Tab = .today
    @State private var shareTarget: ActivityPost?
    @State private var connections: ConnectionsViewModel?
    @State private var profile: ProfileViewModel?
    @State private var bodyModel: StudentBodyViewModel?
    @State private var trainerModel: StudentTrainerViewModel?

    init(container: AppContainer) {
        self.container = container
        let student = container.userID ?? "unknown"
        _home = State(initialValue: StudentHomeViewModel(container: container))
        _history = State(initialValue: HistoryViewModel(studentID: student, logs: container.logs,
                                                        plan: { [plans = container.plans] in try? await plans.activePlan(studentID: student) }))
        _feed = State(initialValue: FeedViewModel(studentID: student, posts: container.posts, photos: container.sharedPhotos,
                                                  processPhoto: { ProfilePhoto.process($0, maxSide: 1080, quality: 0.7) }))
    }

    private var profileButton: AnyView {
        AnyView(ProfileToolbarButton(initials: Avatar.initials(for: container.displayName), photo: container.profilePhoto, action: openProfile))
    }

    var body: some View {
        TabView(selection: $tab) {
            StudentHomeView(model: home, profileButton: profileButton)
                .tabItem { Label(String(localized: "Today"), systemImage: "figure.strengthtraining.traditional") }
                .tag(Tab.today)
            HistoryView(model: history, profileButton: profileButton)
                .tabItem { Label(String(localized: "History"), systemImage: "calendar") }
                .tag(Tab.history)
            FeedView(model: feed, profileButton: profileButton, onShare: { shareTarget = $0 })
                .tabItem { Label(String(localized: "Feed"), systemImage: "sparkles") }
                .tag(Tab.feed)
        }
        .tint(Theme.accent)
        .environment(container.mediaPolicy)
        .task(id: tab) { if tab == .feed { await container.syncListening() } }
        .sheet(item: $shareTarget) { post in
            let actions = ShareActions(config: container.config)
            ShareDestinationSheet(post: post, isAvailable: { actions.isAvailable($0) }, onSelect: { actions.share(post, to: $0) })
        }
        .sheet(isPresented: Binding(get: { profile != nil }, set: { if !$0 { profile = nil } })) {
            if let model = profile { ProfileView(model: model, bodyModel: bodyModel, trainerModel: trainerModel, onOpenConnections: openConnections).environment(container.mediaPolicy) }
        }
        .sheet(isPresented: Binding(get: { connections != nil }, set: { if !$0 { connections = nil } })) {
            if let model = connections {
                ConnectionsView(model: model, gymPicker: { AnyView(GymPickerView(model: container.makeGymPickerModel())) })
            }
        }
    }

    private func openProfile() {
        profile = container.makeProfileModel()
        Task {                                                          // these fill a moment later
            bodyModel = await container.makeStudentBodyModel()
            trainerModel = await container.makeStudentTrainerModel()
        }
    }

    private func openConnections() {
        guard let student = container.userID else { return }
        connections = ConnectionsViewModel(studentID: student, actions: ConnectionsController(container: container),
                                           preferences: container.sharingPreferences, links: container.integrationLinks)
    }
}
