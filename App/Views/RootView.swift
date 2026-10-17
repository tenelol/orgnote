import OrgKit
import SwiftUI

enum AppTab: String, Codable {
    case notes, agenda, todo, search
}

struct RootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("tab") private var tab: AppTab = .notes
    @SceneStorage("paths") private var savedPaths: Data?

    var body: some View {
        @Bindable var router = router
        @Bindable var store = store
        Group {
            switch store.phase {
            case .starting:
                Color(.systemGroupedBackground).ignoresSafeArea()
            case .needsFolder:
                OnboardingView()
            case .ready:
                tabs
            }
        }
        .sheet(isPresented: $router.showCapture) {
            CaptureView()
        }
        .alert(
            store.conflict.map { "\(($0.fileID as NSString).lastPathComponent) が他の端末でも変更されました" } ?? "",
            isPresented: Binding { store.conflict != nil } set: { if !$0 { store.conflict = nil } },
            presenting: store.conflict
        ) { _ in
            Button("この端末の内容を残す") { store.resolveConflict(keepLocal: true) }
            Button("他の端末の内容を使う") { store.resolveConflict(keepLocal: false) }
        } message: { _ in
            Text("残さなかった方は「設定 › バックアップ」に保存されます。")
        }
        .overlay(alignment: .top) { NoticeBanner() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.setActive(phase == .active)
        }
        .onAppear { router.restorePaths(from: savedPaths) }
        .onChange(of: router.paths) { savedPaths = router.encodedPaths() }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("メモ", systemImage: "note.text", value: AppTab.notes) {
                NavigationStack(path: router.path(.notes)) { LibraryView().orgDestinations() }
            }
            Tab("アジェンダ", systemImage: "calendar", value: AppTab.agenda) {
                NavigationStack(path: router.path(.agenda)) { AgendaView().orgDestinations() }
            }
            // Only overdue items earn a badge; a daily count would always be on.
            .badge(store.agenda().overdue.count)
            Tab("TODO", systemImage: "checklist", value: AppTab.todo) {
                NavigationStack(path: router.path(.todo)) { TodoView().orgDestinations() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: router.path(.search)) { SearchView().orgDestinations() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: router.openEditors == 0) { CaptureAccessory() }
    }
}

extension View {
    func orgDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .agenda: AgendaView()
            case let .folder(path): LibraryView(folder: path)
            case let .file(id, line): DocumentView(fileID: id, focusLine: line)
            }
        }
    }
}

/// Sits above the tab bar like the Music mini player, so a new note is always
/// one thumb tap away. Collapses to a compact label when the tab bar minimizes.
private struct CaptureAccessory: View {
    @Environment(AppRouter.self) private var router
    @Environment(LibraryStore.self) private var store
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button {
            router.showCapture = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("新規メモ")
                    .font(.body.weight(.medium))
                if placement != .inline {
                    Spacer(minLength: 8)
                    Text((store.inboxPath as NSString).deletingPathExtension)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("\(store.inboxPath) に追記します")
    }
}

/// Information fades after a few seconds; errors stay until closed so there
/// is always time to read them.
private struct NoticeBanner: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let notice = store.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(notice.isError ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice.isError {
                    Button("閉じる", systemImage: "xmark") { withAnimation { store.notice = nil } }
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, notice.isError ? 4 : 16)
            .padding(.vertical, notice.isError ? 0 : 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice) {
                AccessibilityNotification.Announcement(notice.message).post()
                guard !notice.isError else { return }
                try? await Task.sleep(for: .seconds(4))
                withAnimation { store.notice = nil }
            }
        }
    }
}
