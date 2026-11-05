import XCTest

/// End-to-end flows on a fresh install, in English: the reset launch argument
/// (Debug builds only) clears the library before every test.
@MainActor
final class OrgnoteUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Hosted CI simulators run several times slower than a desktop Mac; a wait
    /// returns as soon as its condition holds, so a generous limit costs nothing.
    private let patience: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-OrgnoteUITestReset", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        getStarted()
    }

    // MARK: Flows

    func testGetStartedCreatesStarterNotebooks() {
        XCTAssertTrue(app.buttons["notebook.Welcome.org"].exists)
        XCTAssertTrue(app.buttons["notebook.Notes.org"].exists)
        XCTAssertTrue(app.buttons["tile.today"].label.contains("1"), "the starter to-do is due today")
    }

    func testNewMemoLandsInNotes() {
        addMemo("Buy oat milk")
        app.buttons["notebook.Notes.org"].tap()
        XCTAssertTrue(app.staticTexts["Buy oat milk"].waitForExistence(timeout: patience))
    }

    func testFinishingATodoFillsTodaysRing() {
        openTab("Agenda")
        XCTAssertTrue(element(labeled: "0 of 1 to-do done today").waitForExistence(timeout: patience))
        app.buttons["Mark as Done"].firstMatch.tap()
        XCTAssertTrue(element(labeled: "1 of 1 to-do done today").waitForExistence(timeout: patience))
    }

    /// VoiceOver meets the day strip as one adjustable element on the chosen
    /// day, not a year of buttons.
    func testDayStripIsOneElementForVoiceOver() {
        openTab("Agenda")
        let strip = element(labeled: "Date")
        XCTAssertTrue(strip.waitForExistence(timeout: patience))
        let today = Date.now.formatted(Date.FormatStyle().month().day().weekday(.wide).locale(Locale(identifier: "en_US")))
        XCTAssertTrue((strip.value as? String)?.hasPrefix(today) == true, "\(strip.value ?? "nil")")
        XCTAssertFalse(app.buttons[today].exists)
    }

    func testSearchFindsAHeading() {
        openTab("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: patience))
        field.tap()
        field.typeText("Checklists")
        XCTAssertTrue(app.staticTexts["Checklists work too"].waitForExistence(timeout: patience))
    }

    func testSortingPutsAMemoOffForLater() {
        addMemo("Call the dentist")
        app.buttons["tile.unsorted"].tap()
        XCTAssertTrue(app.staticTexts["Call the dentist"].waitForExistence(timeout: patience))
        app.buttons["Later"].tap()
        XCTAssertTrue(app.staticTexts["All Sorted"].waitForExistence(timeout: patience))
    }

    func testDeletingANotebook() {
        let cover = app.buttons["notebook.Welcome.org"]
        cover.press(forDuration: 1.0)
        app.buttons["Delete Notebook…"].tap()
        app.buttons["Delete Notebook"].tap()
        XCTAssertTrue(cover.waitForNonExistence(timeout: patience))
        XCTAssertTrue(app.buttons["notebook.Notes.org"].exists)
    }

    // MARK: Steps

    /// iPhone shows a tab bar; iPad shows the same tabs in a sidebar or top bar.
    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.exists { tab.tap() } else { app.buttons[name].firstMatch.tap() }
    }

    /// The progress ring is a plain element in the toolbar, not a button.
    private func element(labeled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func getStarted() {
        let start = app.buttons["onboarding.start"]
        XCTAssertTrue(start.waitForExistence(timeout: patience))
        // Enabled once the iCloud check has answered.
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: patience))
        start.tap()
        XCTAssertTrue(app.buttons["notebook.Welcome.org"].waitForExistence(timeout: patience))
    }

    private func addMemo(_ title: String) {
        app.buttons["capture.open"].tap()
        let add = app.buttons["capture.add"]
        XCTAssertTrue(add.waitForExistence(timeout: patience))
        // The editor takes focus on open, but on a slow simulator keys sent at
        // once can arrive before it does; tapping it first makes sure.
        app.textViews.firstMatch.tap()
        app.typeText(title)
        XCTAssertTrue(add.wait(for: \.isEnabled, toEqual: true, timeout: patience))
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: patience))
    }
}
