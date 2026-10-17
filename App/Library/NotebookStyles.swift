import SwiftUI

/// The cover of a notebook (one .org file). Kept on this device only, so the
/// Org files stay exactly as Neovim wrote them.
struct NotebookStyle: Codable, Hashable {
    var color: String
    var symbol: String

    static let colors: [(name: String, color: Color)] = [
        ("green", .green), ("mint", .mint), ("teal", .teal), ("cyan", .cyan), ("blue", .blue),
        ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("red", .red),
        ("orange", .orange), ("yellow", .yellow), ("brown", .brown), ("gray", .gray),
    ]

    static let symbols = [
        "book.closed", "books.vertical", "text.book.closed", "note.text", "tray",
        "checklist", "briefcase", "graduationcap", "lightbulb", "heart",
        "house", "cart", "airplane", "figure.run", "fork.knife",
        "music.note", "camera", "gamecontroller", "leaf", "star",
        "calendar", "folder", "pencil.and.scribble", "brain",
    ]

    var tint: Color { Self.colors.first { $0.name == color }?.color ?? .gray }
}

@MainActor @Observable
final class NotebookStyles {
    static let shared = NotebookStyles()
    private static let key = "notebookStyles"

    private var styles: [String: NotebookStyle]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        styles = data.flatMap { try? JSONDecoder().decode([String: NotebookStyle].self, from: $0) } ?? [:]
    }

    /// A chosen cover, or a stable default derived from the file name.
    func style(for fileID: String, isCaptureTarget: Bool) -> NotebookStyle {
        if let style = styles[fileID] { return style }
        if isCaptureTarget { return NotebookStyle(color: "gray", symbol: "tray") }
        let palette = NotebookStyle.colors.dropLast()
        let index = fileID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        return NotebookStyle(color: palette[palette.startIndex + index].name, symbol: "book.closed")
    }

    func set(_ style: NotebookStyle, for fileID: String) {
        styles[fileID] = style
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
