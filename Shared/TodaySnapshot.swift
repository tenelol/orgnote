import Foundation

/// The agenda slice the widget shows. The app writes it into the shared App
/// Group container whenever tasks change; the widget never touches the Org
/// folder itself, so it needs no access to iCloud Drive.
nonisolated struct TodaySnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var title: String
        var fileID: String
        var line: Int
        /// Start of the day the item is planned for.
        var day: Date
        var time: String?
        var isDeadline: Bool
        var isDone: Bool
        var priority: String?
    }

    var items: [Item]

    /// Set per build from Config/*.xcconfig, so each publisher uses their own group.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "OrgnoteAppGroup") as? String ?? ""
    static let widgetKind = "TodayTodos"

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("today.json")
    }

    static func load() -> TodaySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.url else { return }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Open items from before `day`, then the items planned for `day`.
    func lists(for day: Date, calendar: Calendar = .current) -> (overdue: [Item], today: [Item]) {
        let start = calendar.startOfDay(for: day)
        let overdue = items.filter { !$0.isDone && $0.day < start }
        let today = items.filter { calendar.isDate($0.day, inSameDayAs: start) }
        return (overdue, today)
    }

    static func url(fileID: String, line: Int) -> URL {
        var components = URLComponents()
        components.scheme = "orgnote"
        components.host = "file"
        components.queryItems = [URLQueryItem(name: "id", value: fileID), URLQueryItem(name: "line", value: String(line))]
        return components.url!
    }

    static let agendaURL = URL(string: "orgnote://agenda")!
}
