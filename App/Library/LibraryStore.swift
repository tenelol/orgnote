import Foundation
import Observation
import OrgKit
import UIKit
import WidgetKit

struct OrgFile: Identifiable {
    var id: String
    var url: URL
    var modified: Date?
    var document: OrgDocument
    var isPlaceholder: Bool

    var name: String { (id as NSString).lastPathComponent }
    var folder: String? {
        let folder = (id as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    /// `#+TITLE:` when present, otherwise the file name without `.org`.
    var displayName: String {
        document.title ?? (name as NSString).deletingPathExtension
    }

    /// The first meaningful line, shown under the title like Notes does.
    var preview: String {
        for (index, line) in document.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#+") || trimmed.hasPrefix(":") { continue }
            if let h = document.headline(at: index) {
                return h.displayTitle.isEmpty ? trimmed : h.displayTitle
            }
            return trimmed
        }
        return "追加のテキストなし"
    }
}

struct SearchHit: Identifiable, Hashable {
    var fileID: String
    var line: Int
    var text: String
    var context: String?
    var id: String { "\(fileID)#\(line)" }
}

/// A message for the banner. Errors stay until dismissed; information fades.
struct Notice: Equatable, Identifiable {
    var message: String
    var isError = false
    var id: String { message }
}

struct FileConflict: Identifiable {
    var fileID: String
    var local: String
    var disk: String
    var id: String { fileID }
}

@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    enum Phase: Equatable {
        case starting, needsFolder, ready
    }

    private(set) var phase: Phase = .starting
    private(set) var files: [String: OrgFile] = [:]
    /// Relative paths of every non-hidden folder, including empty ones.
    private(set) var folders: Set<String> = []
    private(set) var folderURL: URL?
    private(set) var isRefreshing = false
    private(set) var errors: [String: String] = [:]
    var conflict: FileConflict?
    var notice: Notice?

    var inboxPath: String {
        didSet { UserDefaults.standard.set(inboxPath, forKey: Keys.inbox) }
    }

    @ObservationIgnored private var savedText: [String: String] = [:]
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var presenter: FolderPresenter?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var widgetTask: Task<Void, Never>?
    @ObservationIgnored private var publishedWidget: TodaySnapshot?

    private enum Keys {
        static let bookmark = "folderBookmark"
        static let inbox = "inboxPath"
    }

    init() {
        inboxPath = UserDefaults.standard.string(forKey: Keys.inbox) ?? "refile.org"
    }

    // MARK: Folder

    var folderName: String { folderURL?.lastPathComponent ?? "Org" }

    var sortedFiles: [OrgFile] {
        files.values.sorted { ($0.modified ?? .distantPast, $1.id) > ($1.modified ?? .distantPast, $0.id) }
    }

    var inbox: OrgFile? { files[inboxPath] }

    func start() {
        guard phase == .starting else { return }
        #if DEBUG
        // A plain path lets simulator tests run without the document picker.
        if let path = UserDefaults.standard.string(forKey: "OrgnoteFolderPath") {
            open(URL(fileURLWithPath: path))
            return
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: Keys.bookmark),
              let resolved = try? FolderIO.resolve(bookmark: data)
        else {
            phase = .needsFolder
            return
        }
        if resolved.isStale, let fresh = withAccess(resolved.url, { try? FolderIO.bookmark(for: resolved.url) }) {
            UserDefaults.standard.set(fresh, forKey: Keys.bookmark)
        }
        open(resolved.url)
    }

    /// Called with the folder the user picked in the document picker.
    func choose(folder url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            UserDefaults.standard.set(try FolderIO.bookmark(for: url), forKey: Keys.bookmark)
        } catch {
            notice = Notice(message: "フォルダを記憶できませんでした。もう一度選んでください。（\(error.localizedDescription)）", isError: true)
            return
        }
        close()
        open(url)
    }

    private func open(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        folderURL = url
        restoreSnapshot(root: url)
        phase = .ready
        let presenter = FolderPresenter(url: url) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
        Task { await refresh() }
    }

    private func close() {
        flushSaves()
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        folderURL?.stopAccessingSecurityScopedResource()
        folderURL = nil
        files = [:]
        savedText = [:]
        dirty = []
    }

    private func withAccess<T>(_ url: URL, _ body: () -> T) -> T {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return body()
    }

    private func waitUntilReady() async {
        if folderURL != nil { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    // MARK: Sync

    /// Polls modification dates while the app is in front. File presenters cover
    /// most changes, but iCloud Drive does not report every remote update.
    func setActive(_ active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active else {
            flushSaves()
            return
        }
        Task { await refresh() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.refresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refreshQueued = false
            await refresh()
        }
    }

    func refresh() async {
        guard let root = folderURL, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let known = files.mapValues { $0.modified }
        // Placeholders and files shown from the launch snapshot have not been read from disk yet.
        let pending = Set(files.values.filter { $0.isPlaceholder || savedText[$0.id] == nil }.map(\.id))
        let backups = FolderIO.backupDirectory()
        let (infos, folderList, reads, failures, recovered) = await Task.detached {
            let (infos, folderList) = FolderIO.list(root: root)
            var reads: [FileRead] = []
            var failures: [String: String] = [:]
            var recovered = 0
            for info in infos where !info.isPlaceholder {
                guard known[info.id] == nil || known[info.id]! != info.modified || pending.contains(info.id) else { continue }
                recovered += FolderIO.resolveConflicts(at: info.url, backups: backups)
                do {
                    reads.append(FileRead(info: info, text: try FolderIO.read(info.url)))
                } catch {
                    failures[info.id] = error.localizedDescription
                }
            }
            return (infos, folderList, reads, failures, recovered)
        }.value

        if folders != Set(folderList) { folders = Set(folderList) }
        if recovered > 0 { notice = Notice(message: "iCloudで競合した\(recovered)件の版を「設定 › バックアップ」に保存しました") }
        errors = failures

        let present = Set(infos.map(\.id))
        for id in files.keys where !present.contains(id) && !dirty.contains(id) {
            files[id] = nil
            savedText[id] = nil
        }
        for info in infos where info.isPlaceholder && files[info.id] == nil {
            files[info.id] = OrgFile(id: info.id, url: info.url, modified: info.modified,
                                     document: OrgDocument(text: ""), isPlaceholder: true)
        }
        for read in reads {
            apply(diskText: read.text, info: read.info)
        }
        if !reads.isEmpty || !present.isSuperset(of: files.keys) { saveSnapshot() }
        scheduleWidgetUpdate()
    }

    // MARK: Widget

    /// Publishes this week's tasks for the widget, coalescing bursts of edits.
    private func scheduleWidgetUpdate() {
        widgetTask?.cancel()
        widgetTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            publishWidget()
            TaskNotifications.shared.reschedule(self)
        }
    }

    private func publishWidget() {
        let agenda = agenda()
        let items = (agenda.overdue + agenda.days.flatMap(\.items))
            .filter { $0.headline.keyword != nil }
            .map { item in
                TodaySnapshot.Item(
                    id: item.id,
                    title: item.headline.displayTitle.isEmpty ? "無題" : item.headline.displayTitle,
                    fileID: item.fileID, line: item.headline.lineIndex,
                    day: item.date.date(), time: item.time?.string,
                    isDeadline: item.kind == .deadline, isDone: item.headline.isDone,
                    priority: item.headline.priority)
            }
        let snapshot = TodaySnapshot(items: items)
        // Reloading costs the widget's daily budget, so only when something changed.
        guard snapshot != publishedWidget else { return }
        do {
            try snapshot.save()
            publishedWidget = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: TodaySnapshot.widgetKind)
        } catch {
            // The widget keeps its last list; the next change retries.
        }
    }

    // MARK: Snapshot

    /// The last known file contents, shown instantly at launch while the real
    /// folder is read in the background, so opening feels as quick as Notes.
    private nonisolated struct Snapshot: Codable {
        var folder: String
        var files: [String: Entry]
        struct Entry: Codable {
            var text: String
            var modified: Date?
        }
    }

    private var snapshotURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("snapshot.json")
    }

    private func restoreSnapshot(root: URL) {
        guard files.isEmpty,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.folder == root.standardizedFileURL.path
        else { return }
        for (id, entry) in snapshot.files {
            // savedText stays unset, so the first refresh re-reads these files and disk wins.
            files[id] = OrgFile(id: id, url: root.appendingPathComponent(id), modified: entry.modified,
                                document: OrgDocument(text: entry.text), isPlaceholder: false)
        }
    }

    private func saveSnapshot() {
        guard let root = folderURL else { return }
        let snapshot = Snapshot(
            folder: root.standardizedFileURL.path,
            files: files.filter { !$0.value.isPlaceholder }
                .mapValues { Snapshot.Entry(text: $0.document.text, modified: $0.modified) })
        let url = snapshotURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    private func apply(diskText: String, info: FileInfo) {
        let id = info.id
        if savedText[id] == diskText {
            files[id]?.modified = info.modified
            return
        }
        if dirty.contains(id), let local = files[id]?.document.text {
            if local == diskText {
                savedText[id] = diskText
                dirty.remove(id)
            } else if conflict == nil {
                conflict = FileConflict(fileID: id, local: local, disk: diskText)
            }
            return
        }
        savedText[id] = diskText
        files[id] = OrgFile(id: id, url: info.url, modified: info.modified,
                            document: OrgDocument(text: diskText), isPlaceholder: false)
    }

    // MARK: Editing

    func update(_ id: String, text: String) {
        guard var file = files[id], file.document.text != text else { return }
        file.document.replaceText(text)
        file.modified = .now
        files[id] = file
        scheduleSave(id, delay: .milliseconds(800))
    }

    /// Applies a structural edit such as toggling a TODO, then saves quickly.
    func edit(_ id: String, _ change: (inout OrgDocument) -> Void) {
        guard var file = files[id] else { return }
        change(&file.document)
        file.modified = .now
        files[id] = file
        scheduleSave(id, delay: .milliseconds(150))
    }

    private func scheduleSave(_ id: String, delay: Duration) {
        scheduleWidgetUpdate()
        dirty.insert(id)
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await save(id)
        }
    }

    func flushSaves() {
        let ids = dirty
        guard !ids.isEmpty else { return }
        let task = UIApplication.shared.beginBackgroundTask()
        Task {
            for id in ids {
                saveTasks[id]?.cancel()
                await save(id)
            }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func save(_ id: String, force: Bool = false) async {
        guard let file = files[id], dirty.contains(id) else { return }
        let text = file.document.text
        let url = file.url
        let base = savedText[id]
        let result: Result<String?, Error> = await Task.detached {
            Result {
                // Check what is on disk first, so an edit from the Mac is never silently overwritten.
                let disk = FileManager.default.fileExists(atPath: url.path) ? try FolderIO.read(url) : nil
                if !force, let disk, disk != base, disk != text { return disk }
                try FolderIO.write(text, to: url)
                return nil
            }
        }.value

        switch result {
        case let .success(disk?):
            if conflict == nil { conflict = FileConflict(fileID: id, local: text, disk: disk) }
        case .success(nil):
            savedText[id] = text
            if files[id]?.document.text == text { dirty.remove(id) }
            files[id]?.modified = FolderIO.modificationDate(of: url) ?? .now
            saveSnapshot()
        case let .failure(error):
            notice = Notice(message: "\(file.name) を保存できませんでした。編集内容はアプリ内に残っています。（\(error.localizedDescription)）", isError: true)
        }
    }

    func resolveConflict(keepLocal: Bool) {
        guard let conflict, var file = files[conflict.fileID] else { return }
        self.conflict = nil
        if keepLocal {
            FolderIO.backup(conflict.disk, name: file.name)
            Task { await save(conflict.fileID, force: true) }
        } else {
            FolderIO.backup(conflict.local, name: file.name)
            file.document = OrgDocument(text: conflict.disk)
            files[conflict.fileID] = file
            savedText[conflict.fileID] = conflict.disk
            dirty.remove(conflict.fileID)
        }
    }

    // MARK: Capture and files

    /// Appends a capture to the inbox file, creating it when needed.
    @discardableResult
    func capture(
        _ draft: String, keyword: String? = nil, scheduled: OrgDate? = nil, deadline: OrgDate? = nil,
        priority: String? = nil, tags: [String] = [], into target: String? = nil
    ) async -> (fileID: String, line: Int)? {
        let entry = OrgDocument.captureEntry(draft: draft, keyword: keyword, scheduled: scheduled,
                                             deadline: deadline, priority: priority, tags: tags)
        guard !entry.isEmpty else { return nil }
        await waitUntilReady()
        guard let root = folderURL else { return nil }
        if files.isEmpty { await refresh() }
        let id = target ?? inboxPath
        if files[id] == nil {
            files[id] = OrgFile(id: id, url: root.appendingPathComponent(id), modified: .now,
                                document: OrgDocument(text: ""), isPlaceholder: false)
            savedText[id] = nil
        }
        var line = 0
        edit(id) { line = $0.insertSubtree(entry, under: nil) ?? 0 }
        await save(id)
        return dirty.contains(id) ? nil : (id, line)
    }

    /// Deletes an entry with its subtree, keeping a copy in the app's backups.
    /// Returns the removed lines so the deletion can be undone.
    @discardableResult
    func deleteEntry(_ id: String, line: Int) -> [String]? {
        guard let file = files[id], let removed = file.document.subtree(at: line) else { return nil }
        FolderIO.backup(removed.joined(separator: file.document.newline), name: "deleted-\(file.name)")
        edit(id) { $0.removeSubtree(at: line) }
        return removed
    }

    func restoreEntry(_ lines: [String], in id: String, at line: Int) {
        edit(id) { $0.insertLines(lines, at: line) }
    }

    /// Refiles an entry with its subtree under `parent` in `target`, or at the
    /// top level of `target` when `parent` is nil.
    @discardableResult
    func moveEntry(from source: String, line: Int, to target: String, under parent: Int?) -> Bool {
        guard let sourceFile = files[source], let subtree = sourceFile.document.subtree(at: line),
              files[target] != nil
        else { return false }
        let title = sourceFile.document.headline(at: line)?.displayTitle ?? ""
        if source == target {
            // An entry cannot move into its own subtree.
            if let parent, parent >= line, parent < line + subtree.count { return false }
            edit(source) { document in
                document.removeSubtree(at: line)
                document.insertSubtree(subtree, under: parent.map { $0 > line ? $0 - subtree.count : $0 })
            }
        } else {
            // Destination first: if anything fails after this, the entry exists twice, never zero times.
            edit(target) { $0.insertSubtree(subtree, under: parent) }
            edit(source) { $0.removeSubtree(at: line) }
        }
        notice = Notice(message: "「\(title)」を\(files[target]?.displayName ?? target)に移動しました")
        return true
    }

    /// Adds an empty top-level heading to file `id` and returns its line.
    func addHeading(_ title: String, to id: String) -> Int? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard files[id] != nil, !title.isEmpty else { return nil }
        var line: Int?
        edit(id) { line = $0.appendEntry(title: title, created: nil) }
        return line
    }

    func backups() -> [URL] {
        let dir = FolderIO.backupDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Files and folders directly inside `folder` ("" is the root).
    func contents(of folder: String) -> (folders: [String], files: [OrgFile]) {
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        // Folders implied by file paths keep the tree intact while only the launch snapshot is loaded.
        var all = folders
        for id in files.keys {
            var dir = parent(id)
            while !dir.isEmpty, all.insert(dir).inserted { dir = parent(dir) }
        }
        return (all.filter { parent($0) == folder }.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                sortedFiles.filter { parent($0.id) == folder })
    }

    /// Number of files anywhere under `folder`.
    func fileCount(under folder: String) -> Int {
        files.keys.filter { $0.hasPrefix(folder + "/") }.count
    }

    func createFolder(named name: String, in parent: String) async -> String? {
        await waitUntilReady()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = folderURL, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let path = parent.isEmpty ? name : "\(parent)/\(name)"
        let url = root.appendingPathComponent(path, isDirectory: true)
        do {
            try await Task.detached { try FolderIO.createFolder(at: url) }.value
        } catch {
            notice = Notice(message: "フォルダを作成できませんでした。（\(error.localizedDescription)）", isError: true)
            return nil
        }
        folders.insert(path)
        return path
    }

    func createFile(named name: String, in folder: String = "") async -> String? {
        await waitUntilReady()
        guard let root = folderURL else { return nil }
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.contains("/") { return nil }
        if base.lowercased().hasSuffix(".org") { base = String(base.dropLast(4)) }
        let prefix = folder.isEmpty ? "" : "\(folder)/"
        var id = "\(prefix)\(base).org"
        var n = 2
        while files[id] != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path) {
            id = "\(prefix)\(base) \(n).org"
            n += 1
        }
        files[id] = OrgFile(id: id, url: root.appendingPathComponent(id), modified: .now,
                            document: OrgDocument(text: "#+TITLE: \(base)\n\n"), isPlaceholder: false)
        dirty.insert(id)
        await save(id)
        return id
    }

    // MARK: Queries

    func agenda(today: Date = .now) -> Agenda {
        agenda(from: OrgDate(today), days: 7)
    }

    /// The agenda for `days` days starting at `start`; overdue is relative to `start`.
    func agenda(from start: OrgDate, days: Int) -> Agenda {
        Agenda(documents: files.values.filter { !$0.isPlaceholder }.map { ($0.id, $0.document) }, today: start, days: days)
    }

    func search(_ query: String) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for file in sortedFiles {
            for (index, line) in file.document.lines.enumerated() where line.localizedStandardContains(query) {
                let headline = file.document.headline(containing: index)
                let text = file.document.headline(at: index)?.displayTitle
                    ?? line.trimmingCharacters(in: .whitespaces)
                let context = headline.flatMap { $0.lineIndex == index ? nil : $0.displayTitle }
                hits.append(SearchHit(fileID: file.id, line: index, text: text, context: context))
                if hits.count >= 200 { return hits }
            }
        }
        return hits
    }
}
