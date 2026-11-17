import XCTest

// Launches the real app in `-UITestMode`: in-memory SwiftData, a loopback "server", a scriptable network, a seeded plan
// and a deterministic exercise catalogue (`-UITestStubCatalog`) — no Firebase, no network, fully repeatable.
// Elements are found by the accessibility identifiers PresentationKit's views declare: that is the contract between them.

@MainActor
final class StudentWorkoutFlowUITests: FitCoachUITestCase {

    private func openFirstExercise() {
        let start = app.buttons["start-workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let row = app.buttons["exercise-row-blk-bench"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["complete-set-blk-bench-1"].waitForExistence(timeout: 10))
    }

    func testLoadCanBeTypedOnANumericKeypadOrNudgedByOne() throws {
        launch()
        openFirstExercise()

        let field = app.textFields["load-blk-bench-1-field"]
        field.tap()
        // Numeric keypad only: digits are there, letters are not.
        XCTAssertTrue(app.keyboards.keys["5"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.keys["a"].exists)
        field.typeText("55")
        app.buttons["keyboard-done"].tap()
        XCTAssertEqual(field.value as? String, "55")

        app.buttons["load-blk-bench-1-plus"].tap()
        XCTAssertEqual(field.value as? String, "56")
        app.buttons["load-blk-bench-1-minus"].tap()
        app.buttons["load-blk-bench-1-minus"].tap()
        XCTAssertEqual(field.value as? String, "54")
    }

    func testCompletingASetShowsTheRestBarAndMovesToTheNextSet() throws {
        launch()
        openFirstExercise()

        app.buttons["complete-set-blk-bench-1"].tap()
        XCTAssertTrue(app.otherElements["rest-panel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["rest-remaining"].exists)
        app.buttons["rest-skip"].tap()
        XCTAssertFalse(app.otherElements["rest-panel"].waitForExistence(timeout: 1))

        // The card now shows set 2, and the only way back is to undo the LAST performed set (set 1 is locked).
        XCTAssertTrue(app.buttons["complete-set-blk-bench-2"].exists)
        XCTAssertFalse(app.buttons["set-row-blk-bench-1"].exists, "the bottom set list is gone")
        app.buttons["undo-last-blk-bench"].tap()
        XCTAssertTrue(app.buttons["complete-set-blk-bench-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["undo-last-blk-bench"].exists, "nothing left to undo")
    }

    func testSameLoadFollowsOneSharedValueAndLocksTheOtherSets() throws {
        launch()
        openFirstExercise()

        app.switches["same-load-toggle"].tap()
        let plus = app.buttons["load-blk-bench-1-plus"]
        plus.tap(); plus.tap()                                // 40 → 42, for every set that's left
        // Complete set 1: the card moves to set 2, which follows the shared load (42).
        app.buttons["complete-set-blk-bench-1"].tap()
        app.buttons["rest-skip"].tap()
        let field = app.textFields["load-blk-bench-2-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "42")
    }

    func testSubstitutionsAreACollapsedDropdownWithAtMostThree() throws {
        launch()
        openFirstExercise()

        // Collapsed by default: no options on screen until the dropdown is opened.
        let toggle = app.buttons["substitutions-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'use-substitute-'"))
        XCTAssertEqual(options.count, 0, "the dropdown must start collapsed")

        toggle.tap()
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue((1...3).contains(options.count), "Expected 1–3 substitutes, got \(options.count)")
        options.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["swap-banner"].waitForExistence(timeout: 3))
        XCTAssertEqual(options.count, 0, "choosing one collapses the dropdown again")
    }

    func testFinishingTheWorkoutSavesAndReturnsToToday() throws {
        launch()
        openFirstExercise()

        for set in 1...3 {
            app.buttons["complete-set-blk-bench-\(set)"].tap()
            if set < 3 { app.buttons["rest-skip"].tap() }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()    // back to the workout overview
        let finish = app.buttons["finish-workout"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5) && finish.isEnabled)
        finish.tap()

        let eight = app.buttons["rpe-8"]
        XCTAssertTrue(eight.waitForExistence(timeout: 5))
        eight.tap()
        app.buttons["rpe-save"].tap()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 10))   // closed itself, back on "Today"
    }

    func testOfflineWorkoutIsQueuedWithoutAnyCloudBadge() throws {
        launch(offline: true)

        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        // Sync status is handled under the hood: no cloud badge on screen, online or not.
        XCTAssertFalse(app.staticTexts["sync-badge"].exists)

        openFirstExercise()
        app.buttons["complete-set-blk-bench-1"].tap()          // must work with no connectivity at all
        XCTAssertTrue(app.otherElements["rest-panel"].waitForExistence(timeout: 3))
    }

    // MARK: Layout across form factors

    func testContentIsAFullWidthStackOnPhonesAndAReadableColumnOnIPad() throws {
        launch()
        let start = app.buttons["start-workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        if window.width > 700 {
            XCTAssertLessThanOrEqual(start.frame.width, 720, "iPad: content stays a readable column, not edge to edge")
            XCTAssertGreaterThan(start.frame.minX, 40, "…and is centred with margins")
        } else {
            XCTAssertGreaterThan(start.frame.width, window.width * 0.8, "iPhone: full-width, single-hand friendly")
        }
        // The same hero reads correctly on the first day of the A–D split.
        XCTAssertTrue(app.staticTexts["next-workout-label"].label.hasPrefix("Treino A"))
    }

    // MARK: Automatic start, feed and connections

    func testStayingAtTheGymStartsTheWorkoutByItself() throws {
        launch(autoStart: true)

        // The simulated student walked in 31 minutes ago and is still there: no tap needed, the hero reads "in progress".
        let start = app.buttons["start-workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let label = NSPredicate(format: "label CONTAINS[c] 'Resume'")
        expectation(for: label, evaluatedWith: start)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["Workout in progress"].exists)

        start.tap()                                            // resumes the very workout that was started for them
        XCTAssertTrue(app.buttons["exercise-row-blk-bench"].waitForExistence(timeout: 10))
    }

    func testWithoutAGymVisitNothingStartsOnItsOwn() throws {
        launch()
        let start = app.buttons["start-workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.label.contains("Start"))
        XCTAssertFalse(app.staticTexts["Workout in progress"].exists)
    }

    func testFeedShowsCardsAndOffersWhereToShareThem() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Feed"].tap()

        XCTAssertTrue(app.otherElements["post-card-seed-pr"].waitForExistence(timeout: 10)
                      || app.staticTexts["New PR · Supino reto"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Eye of the Tiger  ×3"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Eye of the Tiger'")).firstMatch.exists)

        app.buttons["share-post-seed-pr"].tap()
        for destination in ["whatsapp", "instagramStories", "gymrats", "more"] {
            XCTAssertTrue(app.buttons["share-\(destination)"].waitForExistence(timeout: 5), "missing share option \(destination)")
        }
        XCTAssertTrue(app.buttons["share-gymrats"].isEnabled && app.buttons["share-more"].isEnabled)
    }

    func testFinishingAWorkoutAddsItsCardToTheFeed() throws {
        launch()
        openFirstExercise()
        for set in 1...3 {
            app.buttons["complete-set-blk-bench-\(set)"].tap()
            if set < 3 { app.buttons["rest-skip"].tap() }
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["finish-workout"].tap()
        app.buttons["rpe-8"].tap()
        app.buttons["rpe-save"].tap()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Feed"].tap()
        // The demo student has a few weeks of lighter bench-press history, so finishing at 40 kg is a personal record: the card is the
        // PR card ("New PR · Supino reto"); without a record it would carry the workout's name ("Treino A").
        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Treino A' OR label CONTAINS 'New PR'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the finished workout should produce a card")
    }

    func testConnectionsAreOptInAndExplainedWhenNotSetUp() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["open-connections"].exists, "no settings gear on Today")
        app.tabBars.buttons["Feed"].tap()
        app.buttons["open-profile"].tap()
        app.buttons["open-connections"].tap()

        XCTAssertTrue(app.buttons["choose-gym"].waitForExistence(timeout: 5))
        // No gym chosen yet → automatic start can't be switched on.
        XCTAssertFalse(app.switches["toggle-gym-detection"].isEnabled)
        // This demo build has no Spotify client id and no backend: both say so instead of offering a broken button.
        XCTAssertFalse(app.buttons["connect-spotify"].exists)
        XCTAssertFalse(app.buttons["connect-strava"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not set up'")).count >= 2)
    }

    func testProfileInTheFeedLogsOutAndCPFSignsBackInAsStudent() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        app.buttons["open-profile"].tap()
        XCTAssertTrue(app.staticTexts["profile-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-name"].label, "Aluno Demo")
        app.buttons["log-out"].tap()

        // Signed out → the sign-in screen. A CPF opens the student's area; the field says so as you type.
        let identifier = app.textFields["sign-in-identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["sign-in-button"].isEnabled)
        identifier.tap()
        identifier.typeText("52998224725")
        XCTAssertTrue(app.staticTexts["sign-in-detected"].waitForExistence(timeout: 3))
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText("123456")
        XCTAssertTrue(app.buttons["sign-in-button"].isEnabled)
        app.buttons["sign-in-button"].tap()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 10))
    }

    func testCREFSignsInAsPersonalTrainerAndAnInvalidIdentifierCannotSubmit() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Feed"].tap()
        app.buttons["open-profile"].tap()
        app.buttons["log-out"].tap()

        let identifier = app.textFields["sign-in-identifier"]
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        identifier.tap()
        identifier.typeText("123.456.789-00")                   // wrong check digits
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText("123456")
        XCTAssertFalse(app.buttons["sign-in-button"].isEnabled)
        XCTAssertFalse(app.staticTexts["sign-in-detected"].exists)

        identifier.tap()
        identifier.clearAndType("012345-G/AL")
        XCTAssertTrue(app.staticTexts["sign-in-detected"].waitForExistence(timeout: 3))
        app.buttons["sign-in-button"].tap()
        XCTAssertTrue(app.buttons["add-student"].waitForExistence(timeout: 10))          // the trainer's student list, not the student's Today
        XCTAssertFalse(app.buttons["start-workout"].exists)
    }

    // MARK: Profile at the top-left, reduce motion & data

    func testTheProfileAvatarIsAlwaysAtTheTopLeft() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        for tab in ["Today", "Feed"] {
            app.tabBars.buttons[tab].tap()
            let avatar = app.buttons["open-profile"]
            XCTAssertTrue(avatar.waitForExistence(timeout: 5), "no avatar on \(tab)")
            XCTAssertLessThan(avatar.frame.minX, window.width / 3, "avatar must sit on the left on \(tab)")
            XCTAssertLessThan(avatar.frame.minY, 140, "avatar must sit at the top on \(tab)")
        }
        app.buttons["open-profile"].tap()
        XCTAssertTrue(app.staticTexts["profile-name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["change-photo"].exists && app.buttons["log-out"].exists && app.switches["toggle-data-saver"].exists)
    }

    func testReduceMotionAndDataStartsVideosPausedUntilTapped() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        app.buttons["open-profile"].tap()
        let toggle = app.switches["toggle-data-saver"]
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "1", "the saver must be on")
        app.buttons["Done"].tap()

        openFirstExercise()
        let play = app.buttons["play-video"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "with the saver on, the video must wait for a tap")
        XCTAssertTrue(app.staticTexts["Paused to save data · tap to play"].exists)
        play.tap()
        XCTAssertFalse(app.buttons["play-video"].waitForExistence(timeout: 2), "after the tap the video is allowed to play")
    }

    func testNotBeingOnWiFiPausesVideosAutomatically() throws {
        launch(extra: ["-UITestCellular"])
        openFirstExercise()
        XCTAssertTrue(app.buttons["play-video"].waitForExistence(timeout: 5), "off Wi-Fi the video must not start by itself")
        XCTAssertTrue(app.staticTexts["Not on Wi-Fi · tap to play"].exists)
    }

    func testOnWiFiWithTheSaverOffTheVideoStartsByItself() throws {
        launch()
        openFirstExercise()
        XCTAssertFalse(app.buttons["play-video"].waitForExistence(timeout: 3), "on Wi-Fi the muted clip starts on its own")
    }

    // MARK: Strength / volume weeks

    func testTheStudentIsWarnedWhenLiftingAgainstTheWeeksFocus() throws {
        launch(extra: ["-UITestFocusDemo"])
        openFirstExercise()
        XCTAssertTrue(app.staticTexts["focus-chip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["focus-chip"].label.contains("Volume week"))
        // Planned 40 kg, but the student's best in strength weeks was 35 kg → "focus on execution".
        XCTAssertTrue(app.otherElements["focus-warning"].waitForExistence(timeout: 5) || app.staticTexts["focus-warning"].waitForExistence(timeout: 2))
        let warningText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Focus on execution'")).firstMatch
        XCTAssertTrue(warningText.exists)

        let minus = app.buttons["load-blk-bench-1-minus"]
        for _ in 0..<5 { minus.tap() }                                 // 40 → 35: no longer heavier than the strength week
        XCTAssertFalse(warningText.waitForExistence(timeout: 2))
        app.buttons["load-blk-bench-1-plus"].tap()                      // 36 → warning again
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Focus on execution'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["complete-set-blk-bench-1"].isEnabled, "the warning is advice, it never blocks a set")
    }

    func testWithoutAFocusCycleThereIsNoChipAndNoWarning() throws {
        launch()
        openFirstExercise()
        XCTAssertFalse(app.staticTexts["focus-chip"].exists)
        XCTAssertFalse(app.otherElements["focus-warning"].exists)
    }

    // MARK: The personal trainer

    func testTrainerRegistersAStudentWhoDoesTheFirstAccessAndHasNoWorkoutsUntilThePersonalAddsThem() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()

        // 1) The personal trainer (CREF) registers a student by CPF + name…
        signIn("012345-G/AL", password: "123456")
        tap(app.buttons["add-student"], expecting: app.textFields["new-student-cpf"])
        typeCPF("11144477735", into: app.textFields["new-student-cpf"])
        XCTAssertEqual(app.textFields["new-student-cpf"].value as? String, "111.444.777-35", "the CPF gets its dots and dash as it is typed")
        type("Maria Souza", into: app.textFields["new-student-name"])
        app.buttons["register-student"].tap()
        let row = app.staticTexts["Maria Souza"]
        if !row.waitForExistence(timeout: 10) {
            XCTFail("the student was not registered; the sheet says: \(app.staticTexts["add-student-error"].exists ? app.staticTexts["add-student-error"].label : "nothing")")
        }
        XCTAssertTrue(app.staticTexts["Waiting for first access"].exists)

        // …gives her a private nickname…
        tap(row, expecting: app.textFields["nickname-field"])
        type("Tigresa 7h", into: app.textFields["nickname-field"])
        app.buttons["save-nickname"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Tigresa 7h"].waitForExistence(timeout: 5))
        logOut()

        // 2) …who logs in for the first time with that CPF and name, and fills in the rest.
        tap(app.buttons["first-access"], expecting: app.textFields["first-access-cpf"])
        typeCPF("11144477735", into: app.textFields["first-access-cpf"])
        type("maria  SOUZA", into: app.textFields["first-access-name"])           // case and spacing don't matter
        tap(app.buttons["first-access-continue"], expecting: app.textFields["first-access-email"])
        type("maria@example.com", into: app.textFields["first-access-email"])
        type("28", into: app.textFields["first-access-age"])
        type("170", into: app.textFields["first-access-height"])
        type("65.5", into: app.textFields["first-access-weight"])           // the decimal pad of an en_US phone has a dot, not a comma
        type("longenough", into: app.secureTextFields["first-access-password"])
        type("longenough", into: app.secureTextFields["first-access-password-2"])
        app.buttons["first-access-submit"].tap()
        dismissSavePasswordPrompt()

        // 3) She has no workouts until the personal adds them, and never sees the nickname.
        if !item(containing: "No plan yet").waitForExistence(timeout: 20) {
            let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            let enabled = app.buttons["first-access-submit"].exists ? "submit enabled: \(app.buttons["first-access-submit"].isEnabled)" : "no submit button"
            XCTFail("expected the 'no plan yet' screen after first access. \(enabled). On screen: \(texts)")
        }
        XCTAssertFalse(app.buttons["start-workout"].exists)
        XCTAssertFalse(app.staticTexts["Tigresa 7h"].exists)
        app.tabBars.buttons["Feed"].tap()
        XCTAssertFalse(app.staticTexts["Tigresa 7h"].exists)
        logOut()

        // 4) The personal creates her workouts (the only one who can)…
        signIn("012345-G/AL", password: "123456")
        let nickname = app.staticTexts["Tigresa 7h"]
        XCTAssertTrue(nickname.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No plan yet"].exists)
        tap(nickname, expecting: link("edit-plan"))
        tap(link("edit-plan"), expecting: app.buttons["add-day"])
        app.buttons["add-day"].tap()
        flip(app.switches["toggle-focus"])
        app.buttons["add-exercise-Workout A"].tap()
        let exercise = app.buttons["pick-wger-73"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 10))
        exercise.tap()
        XCTAssertTrue(app.staticTexts["Supino reto"].waitForExistence(timeout: 5))
        app.buttons["save-plan"].tap()
        XCTAssertTrue(app.staticTexts["Plan for Maria"].waitForExistence(timeout: 10) || app.staticTexts["Plano de Maria"].exists)
        logOut()

        // 5) …and now she has a workout to start.
        signIn("11144477735", password: "longenough")
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["next-workout-label"].label.contains("Workout A"))
    }

    func testFirstAccessRefusesAWrongNameWithoutSayingWhichPartWasWrong() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()
        app.buttons["first-access"].tap()
        typeCPF("39053344705", into: app.textFields["first-access-cpf"])             // the seeded demo student's CPF…
        type("Someone Else", into: app.textFields["first-access-name"])              // …with the wrong name
        app.buttons["first-access-continue"].tap()
        let error = app.staticTexts["first-access-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.label.contains("CPF") && error.label.contains("name"))
        XCTAssertFalse(app.textFields["first-access-email"].exists)
    }

    func testTrainerSeesAnIndividualProgressChartAndBuildsItTheirWay() throws {
        launch()
        XCTAssertTrue(app.buttons["start-workout"].waitForExistence(timeout: 15))
        logOut()
        signIn("012345-G/AL", password: "123456")
        let student = app.staticTexts["Aluno Demo"]
        XCTAssertTrue(student.waitForExistence(timeout: 10))
        tap(student, expecting: link("open-evolution"))
        tap(link("open-evolution"), expecting: app.staticTexts["evolution-latest"])

        let chart = app.otherElements["evolution-chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 10) || app.staticTexts["evolution-latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["evolution-latest"].waitForExistence(timeout: 5))
        let strength = app.staticTexts["evolution-latest"].label                      // the default metric: estimated 1RM, in kg
        XCTAssertTrue(strength.contains("kg"))

        // The trainer picks what to measure: rest time → seconds.
        app.buttons["metric-picker"].tap()
        let restOption = item("Rest time")
        XCTAssertTrue(restOption.waitForExistence(timeout: 5), "the metric menu lists rest time")
        restOption.tap()
        let rest = app.staticTexts["evolution-latest"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(rest, toContain: " s"), "rest time is shown in seconds, got \(rest.label)")

        // …and how: bars instead of a line, per week, over all time.
        app.buttons["Bars"].tap()
        app.buttons["Per week"].tap()
        app.buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["evolution-latest"].exists)
        XCTAssertFalse(app.staticTexts["evolution-empty"].exists)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        guard let current = value as? String else { return typeText(text) }
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}