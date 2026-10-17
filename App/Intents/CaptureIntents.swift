import AppIntents

/// Opens the capture sheet. Assign it to the Action Button or Control Center
/// for Notes-like instant capture.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "新規メモ"
    static let description = IntentDescription("Orgnoteのキャプチャ画面を開きます。")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.showCapture = true
        return .result()
    }
}

/// Appends text to the inbox without opening the app, for Siri and Shortcuts.
struct AddToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "インボックスに追加"
    static let description = IntentDescription("テキストをOrgnoteのインボックスに追記します。")

    @Parameter(title: "内容")
    var text: String

    @Parameter(title: "TODOにする", default: false)
    var isTodo: Bool

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = LibraryStore.shared
        store.start()
        guard store.phase == .ready,
              await store.capture(text, keyword: isTodo ? "TODO" : nil) != nil
        else {
            return .result(dialog: "Orgnoteでフォルダを選んでから使ってください。")
        }
        return .result(dialog: "\(store.inboxPath) に追加しました。")
    }
}

struct OrgnoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["\(.applicationName)で新規メモ", "New note in \(.applicationName)"],
            shortTitle: "新規メモ",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AddToInboxIntent(),
            phrases: ["\(.applicationName)に追加", "Add to \(.applicationName)"],
            shortTitle: "インボックスに追加",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
