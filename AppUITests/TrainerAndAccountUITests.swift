import XCTest

// The trainer's follow-up screens, running a workout with the student, the body data, shared photos, the trainer's details seen by the
// student, and the sign-in doors (CPF mask, forgot password). Same demo world as the student tests: "Aluno Demo" (CPF 390.533.447-05,
// password demo123, e-mail aluno@demo.app, 82 kg · 178 cm) belongs to "Personal Demo" (CREF 012345-G/AL).

@MainActor
final class TrainerAndAccountUITests: FitCoachUITestCase {
    private let demoCPF = "39053344705"

    private func openDemoStudentAsTrainer() {
        launch(extra: ["-UITestTrainer"])
        let student = app.staticTexts["Aluno Demo"]
        XCTAssertTrue(student.waitForExistence(timeout: 20))
        tap(student, expecting: link("open-summary"))
    }

    private func firstSession() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-'")).firstMatch
    }

    private func backToRoster() {
        for _ in 0..<6 where !app.buttons["add-student"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.buttons["add-student"].waitForExistence(timeout: 1)
        }
    }

    // MARK: Trainer follow-up

    func testTrainerSummaryShowsAttendanceAndThisWeeksVolume() throws {
        openDemoStudentAsTrainer()
        tap(link("open-summary"), expecting: app.staticTexts["summary-adherence"])
        XCTAssertTrue(app.staticTexts["summary-week-volume"].exists)
        XCTAssertTrue(app.staticTexts["summary-last"].exists)
        XCTAssertTrue(app.staticTexts["summary-adherence"].label.contains("%"))
    }

    func testTrainerReadsAWholeDayInTheStudentsHistory() throws {
        openDemoStudentAsTrainer()
        tap(link("open-history"), expecting: firstSession())
        tap(firstSession(), expecting: link("session-header"))
        XCTAssertTrue(link("session-total-sets").waitForExistence(timeout: 10))
        XCTAssertTrue(link("session-exercise").exists)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "session-set").count, 3, "every set of the day is listed")
    }

    func testTrainerRecordsABodyMeasurementAndTheBMIAndFatFollow() throws {
        openDemoStudentAsTrainer()
        tap(link("open-body"), expecting: app.staticTexts["body-bmi"])
        XCTAssertTrue(app.staticTexts["body-bmi"].label.contains("25.9"), "82 kg at 178 cm is a BMI of 25.9")
        XCTAssertTrue(app.staticTexts["body-height"].label.contains("178"))

        tap(app.buttons["add-measurement"], expecting: app.textFields["measurement-weight"])
        type("80,5", into: app.textFields["measurement-weight"])
        XCTAssertTrue(app.staticTexts["measurement-bmi"].waitForExistence(timeout: 5), "the BMI is previewed while typing")
        type("18", into: app.textFields["measurement-bodyfat"])
        app.buttons["save-measurement"].tap()

        XCTAssertTrue(app.staticTexts["body-fat"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(app.staticTexts["body-fat"], toContain: "18"))
        XCTAssertTrue(waitForLabel(app.staticTexts["body-weight"], toContain: "80.5"))
        XCTAssertTrue(app.staticTexts["body-lean"].exists, "lean mass is worked out from the fat percentage")
    }

    func testTrainerSeesThePhotoTheStudentAttached() throws {
        openDemoStudentAsTrainer()
        tap(link("open-photos"), expecting: link("student-photo-seed-photo"))
        tap(link("student-photo-seed-photo"), expecting: app.buttons["Done"])
    }

    // MARK: Running a workout with the student

    func testAWorkoutRunByTheTrainerShowsUpInTheStudentsHistoryAndMovesTheirRotation() throws {
        openDemoStudentAsTrainer()
        tap(link("run-workout"), expecting: app.buttons["coached-start"])
        tap(app.buttons["coached-start"], expecting: app.buttons["exercise-row-blk-bench"])
        XCTAssertTrue(link("coaching-student").exists, "the header says whose workout this is")
        XCTAssertTrue(app.buttons["add-exercise-to-session"].exists, "the trainer can add an exercise")

        tap(app.buttons["exercise-row-blk-bench"], expecting: app.buttons["complete-set-blk-bench-1"])
        XCTAssertTrue(app.buttons["choose-any-exercise"].waitForExistence(timeout: 5), "and swap it for any other")
        for set in 1...3 {
            app.buttons["complete-set-blk-bench-\(set)"].tap()
            if set < 3 { app.buttons["rest-skip"].tap() }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let finish = app.buttons["finish-workout"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5) && finish.isEnabled)
        finish.tap()
        let rpe = app.buttons["rpe-8"]
        XCTAssertTrue(rpe.waitForExistence(timeout: 5))
        rpe.tap()
        app.buttons["rpe-save"].tap()
        XCTAssertTrue(app.buttons["coached-start"].waitForExistence(timeout: 10), "back on the run-workout screen")

        // The student's phone: the session is in their history, labelled, and the rotation has moved on.
        backToRoster()
        logOut()
        signInAsDemoStudent()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForLabel(app.staticTexts["next-workout-label"], toContain: "Treino B"), "the coached Treino A counted as done")
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(firstSession().waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["With your trainer"].waitForExistence(timeout: 5))
    }

    // MARK: The student's view of their trainer and body

    func testTheStudentSeesTheirTrainersNameAndCREFAndTheirOwnBody() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        app.buttons["open-profile"].tap()
        let name = app.staticTexts["your-trainer-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.label, "Personal Demo")
        XCTAssertTrue(app.staticTexts["your-trainer-cref"].label.contains("012345-G/AL"))

        tap(link("open-body"), expecting: app.staticTexts["body-bmi"])
        XCTAssertTrue(app.staticTexts["body-bmi"].label.contains("25.9"))
        XCTAssertFalse(app.buttons["add-measurement"].exists, "only the trainer adds measurements")
    }

    // MARK: Sign-in doors

    func testTheCPFGetsItsDotsAndDashAsYouType() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()
        let identifier = app.textFields["sign-in-identifier"]
        typeCPF(demoCPF, into: identifier)
        XCTAssertEqual(identifier.value as? String, "390.533.447-05")

        tap(app.buttons["first-access"], expecting: app.textFields["first-access-cpf"])
        typeCPF(demoCPF, into: app.textFields["first-access-cpf"])
        XCTAssertEqual(app.textFields["first-access-cpf"].value as? String, "390.533.447-05")
    }

    func testForgotPasswordWithCPFAndRegisteredEmailThenSignInWithTheNewPassword() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()
        tap(app.buttons["forgot-password"], expecting: app.textFields["reset-cpf"])
        typeCPF(demoCPF, into: app.textFields["reset-cpf"])
        XCTAssertEqual(app.textFields["reset-cpf"].value as? String, "390.533.447-05")
        XCTAssertFalse(app.buttons["reset-send"].isEnabled)
        type("aluno@demo.app", into: app.textFields["reset-email"])
        tap(app.buttons["reset-send"], expecting: app.textFields["reset-code"])
        XCTAssertTrue(app.staticTexts["reset-demo-code"].exists, "a demo build has no mailbox, so it shows the code")

        type("123456", into: app.textFields["reset-code"])
        type("brandnew-pass", into: app.secureTextFields["reset-password"])
        type("brandnew-pass", into: app.secureTextFields["reset-password-2"])
        let confirm = app.buttons["reset-confirm"]
        XCTAssertTrue(confirm.isEnabled, "confirm is enabled once the code and both passwords are filled in (code: \(app.textFields["reset-code"].value as? String ?? "?"))")
        confirm.tap()
        XCTAssertTrue(app.buttons["reset-done"].waitForExistence(timeout: 10),
                      "the password was changed. Error shown: \(app.staticTexts["reset-error"].exists ? app.staticTexts["reset-error"].label : "none")")
        app.buttons["reset-done"].tap()

        XCTAssertTrue(app.staticTexts["sign-in-notice"].waitForExistence(timeout: 5))
        let password = app.secureTextFields["sign-in-password"]
        type("brandnew-pass", into: password)
        app.buttons["sign-in-button"].tap()
        dismissSavePasswordPrompt()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15), "the new password signs the student in")
    }

    func testForgotPasswordGivesNothingAwayAboutWhichEmailsAreRegistered() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()
        tap(app.buttons["forgot-password"], expecting: app.textFields["reset-cpf"])
        typeCPF(demoCPF, into: app.textFields["reset-cpf"])
        type("someone.else@example.com", into: app.textFields["reset-email"])
        tap(app.buttons["reset-send"], expecting: app.textFields["reset-code"])                  // exactly what a matching e-mail does

        type("123456", into: app.textFields["reset-code"])
        type("brandnew-pass", into: app.secureTextFields["reset-password"])
        type("brandnew-pass", into: app.secureTextFields["reset-password-2"])
        let confirm = app.buttons["reset-confirm"]
        XCTAssertTrue(confirm.isEnabled, "confirm is enabled once the code and both passwords are filled in (code: \(app.textFields["reset-code"].value as? String ?? "?"))")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["reset-error"].waitForExistence(timeout: 10), "no code was ever issued for that e-mail")
        XCTAssertFalse(app.buttons["reset-done"].exists)
    }
}
