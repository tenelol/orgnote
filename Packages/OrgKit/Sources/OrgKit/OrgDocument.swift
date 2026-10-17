import Foundation

public struct OrgTodoKeywords: Hashable, Sendable {
    public var active: [String]
    public var done: [String]

    public init(active: [String], done: [String]) {
        self.active = active
        self.done = done
    }

    /// Matches nvim-orgmode's default `org_todo_keywords`.
    public static let `default` = OrgTodoKeywords(active: ["TODO"], done: ["DONE"])

    public var all: [String] { active + done }

    /// Parses the value of a `#+TODO:` line such as `TODO NEXT(n) | DONE(d!)`.
    init?(line value: String) {
        let words = value.split(whereSeparator: \.isWhitespace).map { word in
            String(word.prefix { $0 != "(" })
        }.filter { !$0.isEmpty }
        if let bar = words.firstIndex(of: "|") {
            active = Array(words[..<bar])
            done = Array(words[(bar + 1)...])
        } else if words.count > 1 {
            active = Array(words.dropLast())
            done = [words.last!]
        } else {
            return nil
        }
        if active.isEmpty || done.isEmpty { return nil }
    }
}

public enum PlanningKind: String, Sendable, CaseIterable {
    case scheduled = "SCHEDULED"
    case deadline = "DEADLINE"
    case closed = "CLOSED"
}

public struct PlanningItem: Hashable, Sendable {
    public var kind: PlanningKind
    public var timestamp: OrgTimestamp
    /// Original text, so untouched entries are written back byte for byte.
    var raw: String
}

public struct OrgHeadline: Hashable, Sendable, Identifiable {
    public var id: Int { lineIndex }
    public var lineIndex: Int
    public var level: Int
    public var keyword: String?
    public var isDone: Bool
    public var priority: String?
    public var title: String
    public var tags: [String]
    public var planning: [PlanningItem]
    public var planningLineIndex: Int?
    /// Active timestamps in the title or body, used as appointments.
    public var timestamps: [OrgTimestamp]
    /// First line after this entry's own body (the next headline of any level).
    public var endLineIndex: Int
    /// First line after this entry's subtree.
    public var subtreeEndLineIndex: Int
    public var checkboxes: (done: Int, total: Int)
    /// UTF-16 range of the keyword within the headline line.
    var keywordRange: NSRange?
    /// UTF-16 offset where the keyword or title starts within the headline line.
    var contentStart: Int

    public var scheduled: OrgTimestamp? { planning.first { $0.kind == .scheduled }?.timestamp }
    public var deadline: OrgTimestamp? { planning.first { $0.kind == .deadline }?.timestamp }
    public var closed: OrgTimestamp? { planning.first { $0.kind == .closed }?.timestamp }
    public var isTodo: Bool { keyword != nil && !isDone }

    /// The title without timestamps or link markup, for list rows.
    public var displayTitle: String {
        var text = title
        for (range, _) in OrgTimestamp.all(in: text).reversed() {
            text = (text as NSString).replacingCharacters(in: range, with: "")
        }
        text = OrgSyntax.linkRegex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$2")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func == (lhs: OrgHeadline, rhs: OrgHeadline) -> Bool {
        lhs.lineIndex == rhs.lineIndex && lhs.level == rhs.level && lhs.keyword == rhs.keyword
            && lhs.priority == rhs.priority && lhs.title == rhs.title && lhs.tags == rhs.tags
            && lhs.planning == rhs.planning && lhs.endLineIndex == rhs.endLineIndex
            && lhs.checkboxes == rhs.checkboxes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lineIndex)
        hasher.combine(title)
        hasher.combine(keyword)
    }
}

/// A lossless view of an Org file: `text` round-trips exactly, and every edit
/// rewrites only the lines it touches so diffs stay small for Neovim and Git.
public struct OrgDocument: Sendable {
    public private(set) var lines: [String]
    public let newline: String
    public private(set) var keywords: OrgTodoKeywords
    public private(set) var headlines: [OrgHeadline] = []
    public private(set) var title: String?
    private let defaultKeywords: OrgTodoKeywords

    public init(text: String, defaultKeywords: OrgTodoKeywords = .default) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.components(separatedBy: newline)
        self.defaultKeywords = defaultKeywords
        keywords = defaultKeywords
        reparse()
    }

    public var text: String { lines.joined(separator: newline) }

    public func headline(at lineIndex: Int) -> OrgHeadline? {
        headlines.first { $0.lineIndex == lineIndex }
    }

    /// The entry whose heading or body contains `lineIndex`.
    public func headline(containing lineIndex: Int) -> OrgHeadline? {
        headlines.last { $0.lineIndex <= lineIndex && lineIndex < $0.endLineIndex }
    }

    /// Body lines without the planning line and property drawer.
    public func bodyLines(of headline: OrgHeadline) -> [String] {
        var result: [String] = []
        var inDrawer = false
        for i in (headline.lineIndex + 1)..<headline.endLineIndex where i != headline.planningLineIndex {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased() == ":PROPERTIES:" || trimmed.uppercased() == ":LOGBOOK:" { inDrawer = true; continue }
            if inDrawer { if trimmed.uppercased() == ":END:" { inDrawer = false }; continue }
            result.append(lines[i])
        }
        return result
    }

    // MARK: Parsing

    static let headlineRegex = try! NSRegularExpression(pattern: #"^(\*+)(?:[ \t]+|$)"#)
    static let tagsRegex = try! NSRegularExpression(pattern: #"(?:^|[ \t]+)(:(?:[^\s:]+:)+)[ \t]*$"#)
    static let priorityRegex = try! NSRegularExpression(pattern: #"^\[#([A-Za-z0-9])\][ \t]*"#)
    static let planningLineRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:SCHEDULED|DEADLINE|CLOSED):[ \t]*(?:<[^>]*>|\[[^\]]*\])[ \t]*)+$"#)
    static let planningItemRegex = try! NSRegularExpression(
        pattern: #"(SCHEDULED|DEADLINE|CLOSED):[ \t]*(<[^>]*>|\[[^\]]*\])"#)
    static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*[-+]|[ \t]+\*|[ \t]*\d+[.)])[ \t]+\[([ xX\-]?)\]"#)
    static let todoSettingRegex = try! NSRegularExpression(
        pattern: #"^#\+(?:SEQ_|TYP_)?TODO:[ \t]*(.*)$"#, options: [.caseInsensitive])
    static let titleRegex = try! NSRegularExpression(pattern: #"^#\+TITLE:[ \t]*(.*)$"#, options: [.caseInsensitive])

    private mutating func reparse() {
        keywords = defaultKeywords
        title = nil
        var settings: [OrgTodoKeywords] = []
        for line in lines where line.hasPrefix("#+") {
            if let value = Self.firstGroup(Self.todoSettingRegex, in: line), let parsed = OrgTodoKeywords(line: value) {
                settings.append(parsed)
            } else if title == nil, let value = Self.firstGroup(Self.titleRegex, in: line) {
                title = value.trimmingCharacters(in: .whitespaces)
            }
        }
        if !settings.isEmpty {
            keywords = OrgTodoKeywords(active: settings.flatMap(\.active), done: settings.flatMap(\.done))
        }

        var parsed: [OrgHeadline] = []
        for (i, line) in lines.enumerated() {
            if let h = parseHeadline(line, at: i) { parsed.append(h) }
        }
        for index in parsed.indices {
            let level = parsed[index].level
            parsed[index].endLineIndex = index + 1 < parsed.count ? parsed[index + 1].lineIndex : lines.count
            parsed[index].subtreeEndLineIndex =
                parsed[(index + 1)...].first { $0.level <= level }?.lineIndex ?? lines.count
            fillBody(of: &parsed[index])
        }
        headlines = parsed
    }

    private func parseHeadline(_ line: String, at index: Int) -> OrgHeadline? {
        let ns = line as NSString
        guard let match = Self.headlineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let level = match.range(at: 1).length
        var cursor = match.range.length
        let contentStart = cursor
        var keyword: String?
        var keywordRange: NSRange?

        let rest = ns.substring(from: cursor)
        let firstWord = rest.prefix { !$0.isWhitespace }
        if !firstWord.isEmpty, keywords.all.contains(String(firstWord)) {
            keyword = String(firstWord)
            keywordRange = NSRange(location: cursor, length: (String(firstWord) as NSString).length)
            cursor += keywordRange!.length
            while cursor < ns.length, [" ", "\t"].contains(ns.substring(with: NSRange(location: cursor, length: 1))) {
                cursor += 1
            }
        }

        var remainder = ns.substring(from: cursor)
        var priority: String?
        if let p = Self.priorityRegex.firstMatch(in: remainder, range: NSRange(location: 0, length: (remainder as NSString).length)) {
            priority = (remainder as NSString).substring(with: p.range(at: 1))
            remainder = (remainder as NSString).substring(from: p.range.length)
        }

        var tags: [String] = []
        let remNS = remainder as NSString
        if let t = Self.tagsRegex.firstMatch(in: remainder, range: NSRange(location: 0, length: remNS.length)) {
            tags = remNS.substring(with: t.range(at: 1)).split(separator: ":").map(String.init)
            remainder = remNS.substring(to: t.range.location)
        }

        return OrgHeadline(
            lineIndex: index, level: level, keyword: keyword,
            isDone: keyword.map(keywords.done.contains) ?? false,
            priority: priority, title: remainder.trimmingCharacters(in: .whitespaces), tags: tags,
            planning: [], planningLineIndex: nil, timestamps: [],
            endLineIndex: index + 1, subtreeEndLineIndex: index + 1, checkboxes: (0, 0),
            keywordRange: keywordRange, contentStart: contentStart
        )
    }

    private func fillBody(of headline: inout OrgHeadline) {
        let next = headline.lineIndex + 1
        if next < headline.endLineIndex, let items = Self.planningItems(in: lines[next]) {
            headline.planning = items
            headline.planningLineIndex = next
        }
        var timestamps = OrgTimestamp.all(in: headline.title).map(\.timestamp).filter(\.isActive)
        var done = 0, total = 0
        for i in next..<headline.endLineIndex where i != headline.planningLineIndex {
            let line = lines[i]
            timestamps += OrgTimestamp.all(in: line).map(\.timestamp).filter(\.isActive)
            if let mark = Self.firstGroup(Self.checkboxRegex, in: line) {
                total += 1
                if mark.lowercased() == "x" { done += 1 }
            }
        }
        headline.timestamps = timestamps
        headline.checkboxes = (done, total)
    }

    static func planningItems(in line: String) -> [PlanningItem]? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard planningLineRegex.firstMatch(in: line, range: full) != nil else { return nil }
        let items = planningItemRegex.matches(in: line, range: full).compactMap { m -> PlanningItem? in
            guard let kind = PlanningKind(rawValue: ns.substring(with: m.range(at: 1))),
                  let timestamp = OrgTimestamp.parse(ns.substring(with: m.range(at: 2)))
            else { return nil }
            return PlanningItem(kind: kind, timestamp: timestamp, raw: ns.substring(with: m.range))
        }
        return items.isEmpty ? nil : items
    }

    static func firstGroup(_ regex: NSRegularExpression, in line: String) -> String? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: Editing

    /// Sets the TODO keyword. Completing a repeating task advances its dates
    /// instead, and completing a normal one stamps `CLOSED`, as Org does.
    public mutating func setKeyword(_ keyword: String?, forHeadlineAt lineIndex: Int, now: Date = .now) {
        guard let h = headline(at: lineIndex) else { return }
        let willBeDone = keyword.map(keywords.done.contains) ?? false
        let today = OrgDate(now)

        if willBeDone, !h.isDone, h.planning.contains(where: { $0.kind != .closed && $0.timestamp.repeater != nil }) {
            replaceKeyword(of: h, with: h.isTodo ? h.keyword : keywords.active.first)
            var items = h.planning
            for i in items.indices where items[i].kind != .closed {
                guard let repeater = items[i].timestamp.repeater else { continue }
                items[i].timestamp.date = repeater.next(after: items[i].timestamp.date, today: today)
                items[i].raw = "\(items[i].kind.rawValue): \(items[i].timestamp.string)"
            }
            writePlanning(items, for: headline(at: lineIndex)!)
            return
        }

        replaceKeyword(of: h, with: keyword)
        let updated = headline(at: lineIndex)!
        if willBeDone, !h.isDone {
            setPlanning(.closed, to: .now(active: false, at: now), forHeadlineAt: updated.lineIndex)
        } else if !willBeDone, h.isDone, h.closed != nil {
            setPlanning(.closed, to: nil, forHeadlineAt: updated.lineIndex)
        }
    }

    public mutating func toggleDone(forHeadlineAt lineIndex: Int, now: Date = .now) {
        guard let h = headline(at: lineIndex) else { return }
        let keyword = h.isDone ? keywords.active.first : keywords.done.first
        setKeyword(keyword, forHeadlineAt: lineIndex, now: now)
    }

    /// Cycles none → active keywords → done keywords → none, like `S-<right>` / `cit`.
    public mutating func cycleKeyword(forHeadlineAt lineIndex: Int, now: Date = .now) {
        guard let h = headline(at: lineIndex) else { return }
        let all = keywords.all
        let next: String?
        if let current = h.keyword, let i = all.firstIndex(of: current) {
            next = i + 1 < all.count ? all[i + 1] : nil
        } else {
            next = all.first
        }
        setKeyword(next, forHeadlineAt: lineIndex, now: now)
    }

    public mutating func setPlanning(_ kind: PlanningKind, to timestamp: OrgTimestamp?, forHeadlineAt lineIndex: Int) {
        guard let h = headline(at: lineIndex) else { return }
        var items = h.planning
        if let i = items.firstIndex(where: { $0.kind == kind }) {
            if let timestamp {
                items[i].timestamp = timestamp
                items[i].raw = "\(kind.rawValue): \(timestamp.string)"
            } else {
                items.remove(at: i)
            }
        } else if let timestamp {
            let item = PlanningItem(kind: kind, timestamp: timestamp, raw: "\(kind.rawValue): \(timestamp.string)")
            if kind == .closed { items.insert(item, at: 0) } else { items.append(item) }
        }
        writePlanning(items, for: h)
    }

    public mutating func setPriority(_ priority: String?, forHeadlineAt lineIndex: Int) {
        guard let h = headline(at: lineIndex) else { return }
        let ns = lines[lineIndex] as NSString
        var start = h.contentStart
        if let k = h.keywordRange {
            start = k.location + k.length
            while start < ns.length, ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1 }
        }
        let rest = ns.substring(from: start)
        var line = ns.substring(to: start)
        var body = rest
        if let p = Self.priorityRegex.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            body = (rest as NSString).substring(from: p.range.length)
        }
        if let priority {
            if h.keywordRange != nil, !line.hasSuffix(" ") { line += " " }
            line += "[#\(priority)] "
        }
        lines[lineIndex] = line + body
        reparse()
    }

    /// Toggles a `- [ ]` checkbox on `lineIndex`. Returns false when the line has none.
    @discardableResult
    public mutating func toggleCheckbox(at lineIndex: Int) -> Bool {
        guard lineIndex < lines.count else { return false }
        let ns = lines[lineIndex] as NSString
        guard let m = Self.checkboxRegex.firstMatch(in: lines[lineIndex], range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        let mark = ns.substring(with: m.range(at: 1))
        // Group 1 sits between the brackets; replace the brackets too so `[]` becomes valid.
        let bracket = NSRange(location: m.range(at: 1).location - 1, length: m.range(at: 1).length + 2)
        lines[lineIndex] = ns.replacingCharacters(in: bracket, with: mark.lowercased() == "x" ? "[ ]" : "[X]")
        reparse()
        return true
    }

    /// Appends a top-level entry the way an Org capture template would.
    /// Returns the line index of the new headline.
    @discardableResult
    public mutating func appendEntry(
        title: String, body: String = "", keyword: String? = nil,
        scheduled: OrgTimestamp? = nil, deadline: OrgTimestamp? = nil,
        tags: [String] = [], created: Date? = .now
    ) -> Int {
        let indent = "  "
        var heading = "*"
        if let keyword { heading += " \(keyword)" }
        let cleanTitle = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !cleanTitle.isEmpty { heading += " \(cleanTitle)" }
        if !tags.isEmpty { heading += " :\(tags.joined(separator: ":")):" }

        var entry = [heading]
        let planning = [deadline.map { "DEADLINE: \($0.string)" }, scheduled.map { "SCHEDULED: \($0.string)" }]
            .compactMap { $0 }
        if !planning.isEmpty { entry.append(indent + planning.joined(separator: " ")) }
        if let created { entry.append(indent + OrgTimestamp.now(active: false, at: created).string) }
        let bodyLines = body.components(separatedBy: .newlines)
        if body.contains(where: { !$0.isWhitespace }) {
            entry += bodyLines.map { $0.isEmpty ? "" : indent + $0 }
        }

        let insertAt: Int
        if lines == [""] {
            insertAt = 0
        } else if lines.last == "" {
            insertAt = lines.count - 1
        } else {
            lines.append("")
            insertAt = lines.count - 1
        }
        lines.insert(contentsOf: entry, at: insertAt)
        if lines.last != "" { lines.append("") }
        reparse()
        return insertAt
    }

    // MARK: Subtrees

    /// The entry at `lineIndex` with everything nested under it.
    public func subtree(at lineIndex: Int) -> [String]? {
        guard let h = headline(at: lineIndex) else { return nil }
        return Array(lines[lineIndex..<min(h.subtreeEndLineIndex, contentEnd)])
    }

    /// Removes the entry and its subtree, returning the removed lines.
    @discardableResult
    public mutating func removeSubtree(at lineIndex: Int) -> [String]? {
        guard let removed = subtree(at: lineIndex) else { return nil }
        lines.removeSubrange(lineIndex..<(lineIndex + removed.count))
        if lines.isEmpty { lines = [""] }
        reparse()
        return removed
    }

    /// Inserts a subtree as the last child of the headline at `parentLine`, or
    /// at the end of the file at the top level when `parentLine` is nil. Heading
    /// levels shift so the subtree fits its new place. Returns its first line.
    @discardableResult
    public mutating func insertSubtree(_ subtree: [String], under parentLine: Int?) -> Int? {
        guard let first = subtree.first, let rootLevel = Self.level(of: first) else { return nil }
        let parent = parentLine.flatMap { headline(at: $0) }
        let delta = (parent.map { $0.level + 1 } ?? 1) - rootLevel
        let shifted = subtree.map { line -> String in
            guard let level = Self.level(of: line) else { return line }
            return String(repeating: "*", count: max(1, level + delta)) + line.dropFirst(level)
        }
        // Keep (or add) the file's final newline, which is the empty last element.
        if lines.last != "" { lines.append("") }
        let insertAt = parent.map { min($0.subtreeEndLineIndex, contentEnd) } ?? contentEnd
        lines.insert(contentsOf: shifted, at: insertAt)
        reparse()
        return insertAt
    }

    /// Puts lines back at `index`, e.g. to undo a removal.
    public mutating func insertLines(_ inserted: [String], at index: Int) {
        if lines.last != "" { lines.append("") }
        lines.insert(contentsOf: inserted, at: min(max(index, 0), contentEnd))
        reparse()
    }

    /// Index just past the last line of content, before the final newline's empty element.
    private var contentEnd: Int { lines.last == "" ? lines.count - 1 : lines.count }

    /// Text of the entry's body for previews: planning, drawers, capture stamps
    /// and list markers are left out.
    public func preview(of headline: OrgHeadline, limit: Int = 120, includingChecklists: Bool = true) -> String {
        var words: [String] = []
        for line in bodyLines(of: headline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if let stamp = OrgTimestamp.parse(text), !stamp.isActive { continue }
            if let m = Self.listMarker.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                if !includingChecklists, (text as NSString).substring(with: m.range).contains("[") { continue }
                text = (text as NSString).substring(from: m.range.length)
            }
            words.append(text)
            if words.joined(separator: " ").count >= limit { break }
        }
        return String(words.joined(separator: " ").prefix(limit))
    }

    /// When the entry was captured: the first inactive timestamp alone on a body line.
    public func created(of headline: OrgHeadline) -> OrgTimestamp? {
        for line in bodyLines(of: headline) {
            if let stamp = OrgTimestamp.parse(line.trimmingCharacters(in: .whitespaces)), !stamp.isActive {
                return stamp
            }
        }
        return nil
    }

    static let listMarker = try! NSRegularExpression(pattern: #"^(?:[-+]|\d+[.)])[ \t]+(?:\[[ xX\-]?\][ \t]*)?"#)

    static func level(of line: String) -> Int? {
        let ns = line as NSString
        guard let m = headlineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.range(at: 1).length
    }

    /// Replaces the whole text, keeping the newline style.
    public mutating func replaceText(_ text: String) {
        lines = text.components(separatedBy: newline)
        reparse()
    }

    private mutating func replaceKeyword(of h: OrgHeadline, with keyword: String?) {
        let ns = lines[h.lineIndex] as NSString
        if let range = h.keywordRange {
            if let keyword {
                lines[h.lineIndex] = ns.replacingCharacters(in: range, with: keyword)
            } else {
                var end = range.location + range.length
                while end < ns.length, ns.character(at: end) == 32 || ns.character(at: end) == 9 { end += 1 }
                lines[h.lineIndex] = ns.replacingCharacters(
                    in: NSRange(location: range.location, length: end - range.location), with: "")
            }
        } else if let keyword {
            let needsSpace = h.contentStart < ns.length || !ns.hasSuffix(" ")
            let insertion = h.contentStart < ns.length ? "\(keyword) " : (needsSpace ? " \(keyword)" : keyword)
            let at = h.contentStart < ns.length ? h.contentStart : ns.length
            lines[h.lineIndex] = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: insertion)
        }
        reparse()
    }

    private mutating func writePlanning(_ items: [PlanningItem], for h: OrgHeadline) {
        let content = items.map(\.raw).joined(separator: " ")
        if let index = h.planningLineIndex {
            if items.isEmpty {
                lines.remove(at: index)
            } else {
                let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
                lines[index] = indent + content
            }
        } else if !items.isEmpty {
            lines.insert(String(repeating: " ", count: h.level + 1) + content, at: h.lineIndex + 1)
        }
        reparse()
    }
}
