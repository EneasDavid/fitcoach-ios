import Domain
import PresentationKit
import SwiftUI
import UserNotifications

// NOT COMPILED IN THE AUTHORING ENVIRONMENT — see README → "Verification status".

@main
struct FitCoachApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(container: AppContainer.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AppContainer.shared.backgroundTasks.scheduleAll() }
            // Coming back to the foreground is the cheapest moment to decide any gym visit that crossed the minimum stay.
            if phase == .active { Task { await AppContainer.shared.evaluatePresence() } }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Order matters: Firebase first (production only), then the container, then BGTask registration,
        // which iOS requires to finish before the app finishes launching.
        if AppEnvironment.detect() == .production { FirebaseBootstrap.configure() }
        let container = MainActor.assumeIsolated { AppContainer.shared }
        UNUserNotificationCenter.current().delegate = container.router
        MainActor.assumeIsolated { container.backgroundTasks.register() }
        return true
    }
}

struct RootView: View {
    let container: AppContainer

    var body: some View {
        RoleRootView(role: container.role, factory: LiveAppViewFactory(container: container))
            .task {
                for await url in container.router.deepLinks { container.handle(deepLink: url) }
            }
            .onOpenURL { container.handle(deepLink: $0) }
    }
}

@MainActor
struct LiveAppViewFactory: AppViewFactory {
    let container: AppContainer

    func makeSignInView() -> AnyView { AnyView(AuthFlowView(container: container)) }

    func makeStudentRoot() -> AnyView {
        AnyView(StudentRootView(container: container))
    }

    func makeTrainerRoot() -> AnyView { AnyView(TrainerRootView(container: container)) }
}

/// Sign in (CPF or CREF + password) — "first access" for a student their personal trainer registered (CPF + name) — or "forgot password"
/// (CPF + the e-mail registered at first access).
private struct AuthFlowView: View {
    private enum Route { case signIn, firstAccess, resetPassword }

    let container: AppContainer
    @State private var signIn: SignInViewModel
    @State private var firstAccess: FirstAccessViewModel
    @State private var reset: PasswordResetViewModel
    @State private var route: Route = .signIn
    @State private var notice: String?
    @State private var prefill = ""

    init(container: AppContainer) {
        self.container = container
        _signIn = State(initialValue: SignInViewModel(auth: container.authentication, onSignedIn: { await container.completeSignIn($0) }))
        _firstAccess = State(initialValue: FirstAccessViewModel(service: container.firstAccess, onSignedIn: { await container.completeSignIn($0) }))
        _reset = State(initialValue: PasswordResetViewModel(service: container.passwordReset))
    }

    var body: some View {
        switch route {
        case .firstAccess:
            FirstAccessView(model: firstAccess, onBack: { route = .signIn })
        case .resetPassword:
            PasswordResetView(model: reset, onBack: { route = .signIn }, onDone: { cpf in
                prefill = cpf
                notice = String(localized: "Password changed. Sign in with the new one.")
                reset = PasswordResetViewModel(service: container.passwordReset)       // a clean form next time
                route = .signIn
            })
        case .signIn:
            SignInView(model: signIn, onFirstAccess: { notice = nil; route = .firstAccess }, onForgotPassword: { notice = nil; route = .resetPassword },
                       notice: notice, prefill: prefill)
        }
    }
}
