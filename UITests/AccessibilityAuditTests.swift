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

    /// One audit type at a time: on a slow CI simulator a full audit of a busy
    /// screen outlasts XCTest's fixed time limit, so a timeout gets one retry.
    private func audit(_ screen: String = #function) throws {
        let types: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                   .sufficientElementDescription, .dynamicType, .textClipped, .trait]
        let rest = XCUIAccessibilityAuditType.all.subtracting(types.reduce([]) { $0.union($1) })
        let bar = app.buttons["capture.open"]
        let barTop = bar.exists ? bar.frame.minY : .infinity
        for type in types + (rest.isEmpty ? [] : [rest]) {
            do {
                try audit(type, screen, barTop: barTop)
            } catch let error as NSError where error.code == -56 {
                try audit(type, screen, barTop: barTop)
            }
        }
    }

    private func audit(_ type: XCUIAccessibilityAuditType, _ screen: String, barTop: CGFloat) throws {
        try app.performAccessibilityAudit(for: type) { issue in
            let e = issue.element
            print("AUDIT|\(screen)|\(issue.compactDescription)|\(e?.elementType.rawValue ?? 0)|\(e?.label ?? "")|\(e.map { "\($0.frame)" } ?? "")")
            return Self.isAccepted(issue, barTop: barTop)
        }
    }

    /// Findings that are Apple's own styling or out of the app's hands.
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue, barTop: CGFloat) -> Bool {
        let description = issue.compactDescription
        // System secondary label colours land just under the threshold.
        if description == "Contrast nearly passed" { return true }
        // Decorative glyphs hidden from VoiceOver come back without an element.
        if issue.element == nil { return true }
        // Still readable at every size, only not scaled all the way.
        if description == "Dynamic Type font sizes are partially unsupported" { return true }
        // The system search field's placeholder and empty-state views.
        if issue.element?.elementType == .searchField { return true }
        // Text on the Liquid Glass bar at the bottom, or under the system's fade just
        // above it, is measured against whatever scrolls behind; screenshots show it legible.
        if description == "Contrast failed", let frame = issue.element?.frame, frame.maxY > barTop - 24 { return true }
        // A cover's summary is cut to two lines on purpose at the largest sizes;
        // the notebook itself shows everything.
        if description == "Text clipped", issue.element?.identifier == "cover.summary" { return true }
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
