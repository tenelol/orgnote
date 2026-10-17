import SwiftUI

@main
struct OrgnoteApp: App {
    @State private var store = LibraryStore.shared
    @State private var router = AppRouter.shared
    @State private var styles = NotebookStyles.shared
    @State private var recents = RecentEntries.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .environment(styles)
                .environment(recents)
                .onAppear { store.start() }
        }
    }
}

enum Route: Hashable, Codable {
    case agenda
    case folder(String)
    case notebook(String)
    /// One entry of a notebook, opened on its own.
    case entry(String, line: Int)
    case file(String, line: Int?)
}

/// Shared navigation state, so App Intents can open the capture sheet and
/// each tab's stack can be restored on the next launch.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var showCapture = false
    var showTriage = false
    /// Set to switch tabs from inside a tab, e.g. the "today" tile.
    var requestedTab: AppTab?
    /// One-shot request to capture into a given file instead of the default.
    var captureTarget: String?
    /// One-shot request to open capture with TODO already on.
    var captureStartsAsTodo = false
    var paths: [AppTab: [Route]] = [:]
    /// Number of editors on screen; the capture accessory steps aside while writing.
    var openEditors = 0

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding { self.paths[tab] ?? [] } set: { self.paths[tab] = $0 }
    }

    func encodedPaths() -> Data? {
        try? JSONEncoder().encode(paths.mapKeys(\.rawValue))
    }

    func restorePaths(from data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode([String: [Route]].self, from: data) else { return }
        paths = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in AppTab(rawValue: key).map { ($0, value) } })
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
