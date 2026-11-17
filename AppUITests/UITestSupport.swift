import XCTest

/// What every UI test file shares: launching the real app in `-UITestMode` (in-memory stores, a loopback "server", a deterministic exercise
/// catalogue — no Firebase, no network) and the few gestures that need care. Elements are found by the accessibility identifiers
/// PresentationKit's views declare: that is the contract between them.
@MainActor
class FitCoachUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Apple's Passwords ("Save Password?" / "Strong Password") is a system sheet that covers the app and swallows taps. It is the right
        // behaviour for real users, so tests answer it like a person would — whenever it shows up, not only at the steps where it is expected.
        addUIInterruptionMonitor(withDescription: "Apple Passwords") { prompt in
            for label in ["Not Now", "Agora Não", "Never for This Website", "Nunca para Este Site", "Cancel", "Cancelar"] {
                let button = prompt.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    func launch(offline: Bool = false, autoStart: Bool = false, extra: [String] = []) {
        // Pin the language so identifiers/labels are stable whatever the simulator's language is.
        app.launchArguments = ["-UITestMode", "-UITestStubCatalog", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (offline ? ["-UITestOffline"] : []) + (autoStart ? ["-UITestAutoStart"] : []) + extra
        app.launch()
    }

    /// After a login or an account creation iOS offers to save the password ("Save Password?" / "Salvar Senha?"). It is the right behaviour
    /// for real users, but the sheet covers the whole app and swallows every tap — so tests answer it the way a person would: "Not Now".
    func dismissSavePasswordPrompt() {
        for label in ["Not Now", "Agora Não"] {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); return }
        }
        app.tap()                  // nothing visible: this also lets the interruption monitor above run if a sheet is about to appear
    }

    /// The profile avatar sits at the top-left of every main screen, student and trainer alike.
    func logOut() {
        let avatar = app.buttons["open-profile"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        app.buttons["log-out"].tap()
    }

    func signIn(_ identifier: String, password: String) {
        let field = app.textFields["sign-in-identifier"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(identifier)
        let secret = app.secureTextFields["sign-in-password"]
        secret.tap(); secret.typeText(password)
        app.buttons["sign-in-button"].tap()
        dismissSavePasswordPrompt()
    }

    /// A Toggle with a text label inside a List row: the middle of the row is the label, the switch is at the right edge.
    func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// SwiftUI `NavigationLink`s in a List don't always surface as `button`s: find them by identifier whatever their type.
    func link(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    /// An element by its visible text, whatever role the system gives it (menu items, rows, buttons).
    func item(_ label: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch }

    /// An element whose visible text contains the given text (a `ContentUnavailableView` reads as "title, description").
    func item(containing text: String) -> XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch }

    /// Taps and checks that something happened; a tap that lands in the middle of a screen transition is retried.
    func tap(_ element: XCUIElement, expecting next: XCUIElement, attempts: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing \(element)", file: file, line: line)
        for _ in 0..<attempts {
            if element.isHittable { element.tap() }
            if next.waitForExistence(timeout: 3) { return }
        }
        XCTFail("tapping \(element) never produced \(next)", file: file, line: line)
    }

    func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.tap()
        element.typeText(text)
    }

    /// Accessibility labels refresh a beat after the UI changes; poll instead of reading them once.
    func waitForLabel(_ element: XCUIElement, toContain text: String, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.label.contains(text)
    }

    /// The Demo student ("Aluno Demo") signed in with the CPF and password the demo seeds.
    func signInAsDemoStudent(password: String = "demo123") { signIn("39053344705", password: password) }

    /// The Demo trainer ("Personal Demo"), signed in with a CREF.
    func signInAsDemoTrainer() { signIn("012345-G/AL", password: "123456") }
}
