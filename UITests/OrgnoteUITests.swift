import XCTest

/// End-to-end flows on a fresh install, in English: the reset launch argument
/// (Debug builds only) clears the library before every test.
@MainActor
final class OrgnoteUITests: XCTestCase {
    private var app: XCUIApplication!

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
        XCTAssertTrue(app.staticTexts["Buy oat milk"].waitForExistence(timeout: 5))
    }

    func testFinishingATodoFillsTodaysRing() {
        openTab("Agenda")
        XCTAssertTrue(element(labeled: "0 of 1 to-do done today").waitForExistence(timeout: 5))
        app.buttons["Mark as Done"].firstMatch.tap()
        XCTAssertTrue(element(labeled: "1 of 1 to-do done today").waitForExistence(timeout: 5))
    }

    func testSearchFindsAHeading() {
        openTab("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Checklists")
        XCTAssertTrue(app.staticTexts["Checklists work too"].waitForExistence(timeout: 5))
    }

    func testSortingPutsAMemoOffForLater() {
        addMemo("Call the dentist")
        app.buttons["tile.unsorted"].tap()
        XCTAssertTrue(app.staticTexts["Call the dentist"].waitForExistence(timeout: 5))
        app.buttons["Later"].tap()
        XCTAssertTrue(app.staticTexts["All Sorted"].waitForExistence(timeout: 5))
    }

    func testDeletingANotebook() {
        let cover = app.buttons["notebook.Welcome.org"]
        cover.press(forDuration: 1.0)
        app.buttons["Delete Notebook…"].tap()
        app.buttons["Delete Notebook"].tap()
        XCTAssertTrue(cover.waitForNonExistence(timeout: 5))
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
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        // Enabled once the iCloud check has answered.
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["notebook.Welcome.org"].waitForExistence(timeout: 10))
    }

    private func addMemo(_ title: String) {
        app.buttons["capture.open"].tap()
        let add = app.buttons["capture.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // The editor takes focus on open.
        app.typeText(title)
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 5))
    }
}
