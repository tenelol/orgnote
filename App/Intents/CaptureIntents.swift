import AppIntents

/// Opens the capture sheet. Assign it to the Action Button or Control Center
/// for Notes-like instant capture.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Memo"
    static let description = IntentDescription("Opens the new memo screen in Orgnote.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.showCapture = true
        return .result()
    }
}

/// Appends text to the inbox without opening the app, for Siri and Shortcuts.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Memo"
    static let description = IntentDescription("Adds text to where new memos are saved (refile.org by default).")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Make To-do", default: false)
    var isTodo: Bool

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = LibraryStore.shared
        store.start()
        guard store.phase == .ready,
              await store.capture(text, keyword: isTodo ? "TODO" : nil) != nil
        else {
            return .result(dialog: "Choose a folder in Orgnote first.")
        }
        return .result(dialog: "Added to \(store.inboxPath).")
    }
}

struct OrgnoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)"],
            shortTitle: "New Memo",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: ["Add to \(.applicationName)"],
            shortTitle: "Add Memo",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
