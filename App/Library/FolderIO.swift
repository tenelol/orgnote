import Foundation

/// Metadata for one `.org` file found in the library folder.
nonisolated struct FileInfo: Sendable, Equatable {
    var id: String
    var url: URL
    var modified: Date?
    /// The file exists in iCloud but has not been downloaded yet.
    var isPlaceholder: Bool
}

nonisolated struct FileRead: Sendable {
    var info: FileInfo
    var text: String
}

nonisolated enum FolderIOError: LocalizedError {
    case notUTF8(String)

    var errorDescription: String? {
        switch self {
        case let .notUTF8(name): String(localized: "\(name) can’t be read as UTF-8 text")
        }
    }
}

/// File system access for a user-chosen folder. All calls block, so callers
/// run them off the main actor. Reads and writes go through NSFileCoordinator
/// so iCloud Drive sees them as proper document operations.
nonisolated enum FolderIO {
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    /// Lists `.org` files and folders recursively, skipping hidden folders. iCloud
    /// placeholders (`.name.org.icloud`) are reported under their real name and their download starts.
    static func list(root: URL) -> (files: [FileInfo], folders: [String]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return ([], []) }

        let rootPath = root.standardizedFileURL.path
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        }
        var result: [FileInfo] = []
        var folders: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() } else { folders.append(relative(url)) }
                continue
            }

            var realURL = url
            var placeholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
                placeholder = true
            } else if name.hasPrefix(".") {
                continue
            }
            guard realURL.pathExtension.lowercased() == "org" else { continue }

            if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                placeholder = true
            }
            if placeholder {
                try? FileManager.default.startDownloadingUbiquitousItem(at: realURL)
            }

            result.append(FileInfo(id: relative(realURL), url: realURL,
                                   modified: values?.contentModificationDate, isPlaceholder: placeholder))
        }
        return (result, folders)
    }

    /// Where notes live when the user has not picked a folder: the app's own
    /// iCloud Drive folder ("Orgnote"), or the device when iCloud is off. The
    /// iCloud lookup can block, so call this off the main actor.
    static func appFolder(iCloud: Bool) -> URL? {
        let url = iCloud
            ? FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true)
            : URL.documentsDirectory
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the starter notebooks into an empty folder and returns the
    /// inbox's name; a folder that already has notes is left alone.
    static func seedWelcome(in root: URL) -> String? {
        guard list(root: root).files.isEmpty else { return nil }
        let notes = WelcomeNotes.notes()
        for note in [notes.inbox, notes.tour] {
            try? write(note.text, to: root.appendingPathComponent(note.name))
        }
        return notes.inbox.name
    }

    static func createFolder(at url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    static func read(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw FolderIOError.notUTF8(url.lastPathComponent)
                }
                return text
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func write(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Moves the file to the Trash where the volume has one (iCloud Drive's
    /// Recently Deleted), and deletes it outright where it does not.
    static func delete(_ url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            result = Result {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch CocoaError.featureUnsupported {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Resolves iCloud version conflicts by keeping the current file and
    /// copying every losing version into `backups`. Returns how many were saved.
    static func resolveConflicts(at url: URL, backups: URL) -> Int {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return 0 }
        var saved = 0
        for version in versions {
            let stamp = ISO8601DateFormatter().string(from: version.modificationDate ?? .now)
            let target = backups.appendingPathComponent("\(stamp)-\(version.localizedNameOfSavingComputer ?? "icloud")-\(url.lastPathComponent)")
            if (try? FileManager.default.copyItem(at: version.url, to: target)) != nil { saved += 1 }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return saved
    }

    static func backupDirectory() -> URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keeps a copy of text that is about to be replaced, so no choice in a conflict loses data.
    static func backup(_ text: String, name: String) {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "")
        let url = backupDirectory().appendingPathComponent("\(stamp)-\(name.replacingOccurrences(of: "/", with: "_"))")
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Forwards file presenter callbacks for the library folder.
nonisolated final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}
