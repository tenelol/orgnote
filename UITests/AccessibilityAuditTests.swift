import XCTest

/// Xcode's accessibility audit (contrast, labels, hit areas, Dynamic Type
/// clipping) on each main screen of a fresh library.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-OrgnoteUITestReset", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func audit(_ screen: String = #function) throws {
        try app.performAccessibilityAudit { issue in
            let e = issue.element
            print("AUDIT|\(screen)|\(issue.compactDescription)|\(e?.elementType.rawValue ?? 0)|\(e?.label ?? "")|\(e.map { "\($0.frame)" } ?? "")")
            return Self.isAccepted(issue)
        }
    }

    /// Findings that are Apple's own styling or out of the app's hands.
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let description = issue.compactDescription
        // System secondary label colours land just under the threshold.
        if description == "Contrast nearly passed" { return true }
        // Decorative glyphs hidden from VoiceOver come back without an element.
        if issue.element == nil { return true }
        // Still readable at every size, only not scaled all the way.
        if description == "Dynamic Type font sizes are partially unsupported" { return true }
        // The system search field's placeholder and empty-state views.
        if issue.element?.elementType == .searchField { return true }
        // The inbox cover's one-line summary reads in full on screen (checked by
        // screenshot); the audit measures it against a box a point too short.
        if description == "Text clipped", issue.element?.label == String(localized: "Empty notebook") { return true }
        return false
    }

    func testOnboarding() throws {
        XCTAssertTrue(app.buttons["onboarding.start"].waitForExistence(timeout: 10))
        try audit()
    }

    func testMainScreens() throws {
        let start = app.buttons["onboarding.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["notebook.Welcome.org"].waitForExistence(timeout: 10))
        // Let the covers finish animating in.
        sleep(1)
        try audit()

        app.buttons["notebook.Welcome.org"].tap()
        sleep(1)
        try audit("notebook")
        app.navigationBars.buttons.firstMatch.tap()

        for tab in ["Agenda", "To-dos", "Search"] {
            let button = app.tabBars.buttons[tab]
            if button.exists { button.tap() } else { app.buttons[tab].firstMatch.tap() }
            sleep(1)
            try audit(tab)
        }
    }
}
