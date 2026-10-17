import OrgKit
import UIKit

/// Turns Org markup into a note-like view without changing a single character
/// of the text: markup is shrunk to nothing, and controls such as checkboxes
/// and date chips are drawn as overlays. Lines in `revealed` (where the caret
/// is) stay raw so they can be edited directly.
enum LivePreview {
    struct Overlay: Hashable {
        enum Kind: Hashable {
            case todo(done: Bool)
            case checkbox(checked: Bool)
            case bullet
            case planning([Chip])
            case timestamp(String)
            case priority(String)
            /// A date written inside a title or paragraph, drawn over its own text.
            case inlineDate(String, length: Int)
        }

        var kind: Kind
        var line: Int
        /// The character whose layout positions the overlay.
        var anchor: Int
        /// Distance from the text's left edge to the overlay's slot.
        var indent: CGFloat
        var font: UIFont
    }

    struct Chip: Hashable {
        var kind: PlanningKind
        var title: String
        var symbol: String
        var isAlert: Bool
    }

    /// Width of the slot in front of a task or checklist item for its button.
    static let slot: CGFloat = 34
    static let nestStep: CGFloat = 20

    static let hidden: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 0.01),
        .foregroundColor: UIColor.clear,
        .strikethroughStyle: 0,
        .underlineStyle: 0,
        .backgroundColor: UIColor.clear,
    ]

    static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+]|\d+[.)])([ \t]+)(?:(\[([ xX\-]?)\])([ \t]+|$))?"#)
    static let priorityRegex = try! NSRegularExpression(pattern: #"^\[#([A-Za-z0-9])\][ \t]*"#)
    static let tagsRegex = try! NSRegularExpression(pattern: #"[ \t]+(:(?:[^\s:]+:)+)[ \t]*$"#)
    static let linkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\](?:\[([^\]]+)\])?\]"#)
    static let emphasisRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])([*/_+=~])(?=\S)(.+?)(?<=\S)\1(?![\p{L}\p{N}])"#)

    static func apply(
        to storage: NSTextStorage, document: OrgDocument, revealed: Set<Int>, today: OrgDate = OrgDate(.now)
    ) -> [Overlay] {
        let newlineLength = (document.newline as NSString).length
        var overlays: [Overlay] = []
        var inDrawer = false
        var start = 0

        for (index, line) in document.lines.enumerated() {
            let lineStart = start
            let ns = line as NSString
            start += ns.length + newlineLength
            let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
            let opensDrawer = trimmed == ":PROPERTIES:" || trimmed == ":LOGBOOK:"
            defer {
                if opensDrawer { inDrawer = true } else if inDrawer, trimmed == ":END:" { inDrawer = false }
            }
            guard !revealed.contains(index), ns.length > 0 else { continue }

            func hide(_ location: Int, _ length: Int) {
                guard length > 0 else { return }
                storage.addAttributes(hidden, range: NSRange(location: lineStart + location, length: length))
            }
            func paragraph(_ configure: (NSMutableParagraphStyle) -> Void) {
                let range = NSRange(location: lineStart, length: ns.length)
                let style = NSMutableParagraphStyle()
                if let current = storage.attribute(.paragraphStyle, at: lineStart, effectiveRange: nil) as? NSParagraphStyle {
                    style.setParagraphStyle(current)
                }
                configure(style)
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
            func collapse(height: CGFloat) {
                hide(0, ns.length)
                paragraph {
                    $0.minimumLineHeight = height
                    $0.maximumLineHeight = max(height, 0.01)
                    $0.lineSpacing = 0
                    $0.paragraphSpacing = 0
                    $0.paragraphSpacingBefore = height > 1 ? 2 : 0
                }
            }

            let owner = document.headline(containing: index)
            let bodyIndent = owner?.keyword != nil ? slot : 0

            // Headlines: the stars and keyword give way to size and a task button.
            if let headline = document.headlines.first(where: { $0.lineIndex == index }) {
                var cursor = 0
                while cursor < ns.length, ns.character(at: cursor) == 42 { cursor += 1 }
                while cursor < ns.length, ns.character(at: cursor) == 32 || ns.character(at: cursor) == 9 { cursor += 1 }
                if let keyword = headline.keyword {
                    cursor += (keyword as NSString).length
                    while cursor < ns.length, ns.character(at: cursor) == 32 || ns.character(at: cursor) == 9 { cursor += 1 }
                }
                hide(0, min(cursor, ns.length))
                let font = storage.attribute(.font, at: lineStart + min(cursor, max(ns.length - 1, 0)), effectiveRange: nil) as? UIFont
                    ?? EditorTheme.headlineFont(headline.level)
                if headline.keyword != nil {
                    paragraph { $0.firstLineHeadIndent = slot; $0.headIndent = slot }
                    overlays.append(Overlay(kind: .todo(done: headline.isDone), line: index,
                                            anchor: lineStart + min(cursor, ns.length - 1), indent: 0, font: font))
                }
                let rest = ns.substring(from: min(cursor, ns.length)) as NSString
                if let p = priorityRegex.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                    // Clear and shrunk to roughly the width of the "!!!" overlay drawn on top.
                    storage.addAttributes([.foregroundColor: UIColor.clear,
                                           .font: font.withSize(font.pointSize * 0.5)],
                                          range: NSRange(location: lineStart + cursor, length: p.range.length))
                    overlays.append(Overlay(kind: .priority(PriorityLabel.marks(rest.substring(with: p.range(at: 1)))),
                                            line: index, anchor: lineStart + cursor, indent: 0, font: font))
                }
                if let t = tagsRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let tags = t.range(at: 1)
                    storage.addAttributes([.foregroundColor: UIColor.tintColor, .strikethroughStyle: 0],
                                          range: NSRange(location: lineStart + tags.location, length: tags.length))
                    for offset in tags.location..<(tags.location + tags.length) where ns.character(at: offset) == 58 {
                        hide(offset, 1)
                        if offset > tags.location {
                            storage.addAttribute(.kern, value: 6, range: NSRange(location: lineStart + offset - 1, length: 1))
                        }
                    }
                }
                styleInline(line: ns, from: cursor, hide: hide)
                overlays += inlineDates(storage, line: ns, lineStart: lineStart, from: cursor, index: index, today: today)
                continue
            }

            if inDrawer || opensDrawer {
                collapse(height: 0.01)
                continue
            }

            // The planning line becomes a row of tappable date chips.
            if let owner, owner.planningLineIndex == index {
                // Dates to act on come first; the completion stamp trails.
                let chips = owner.planning
                    .sorted { ($0.kind == .closed ? 1 : 0) < ($1.kind == .closed ? 1 : 0) }
                    .map { chip(for: $0, isDone: owner.isDone, today: today) }
                collapse(height: 30)
                overlays.append(Overlay(kind: .planning(chips), line: index, anchor: lineStart,
                                        indent: bodyIndent, font: EditorTheme.small))
                continue
            }

            // A lone inactive timestamp (the capture time) becomes a quiet label.
            let plain = line.trimmingCharacters(in: .whitespaces)
            if let timestamp = OrgTimestamp.parse(plain), !timestamp.isActive {
                collapse(height: 22)
                overlays.append(Overlay(kind: .timestamp(label(for: timestamp, today: today)), line: index,
                                        anchor: lineStart, indent: bodyIndent, font: EditorTheme.small))
                continue
            }

            if plain.uppercased().hasPrefix("#+TITLE:") {
                let prefix = (line as NSString).range(of: ":").location + 1
                var cursor = prefix
                while cursor < ns.length, ns.character(at: cursor) == 32 { cursor += 1 }
                hide(0, cursor)
                storage.addAttributes([.font: EditorTheme.font(.title1, weight: .bold), .foregroundColor: UIColor.label],
                                      range: NSRange(location: lineStart + cursor, length: ns.length - cursor))
                continue
            }
            if plain.hasPrefix("#") { continue }

            // List items: bullets and checkboxes become controls in a slot.
            if let m = listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let depth = CGFloat(max(0, m.range(at: 1).length - (owner.map { $0.level + 1 } ?? 0)) / 2)
                let indent = bodyIndent + depth * nestStep
                hide(0, m.range.length)
                paragraph { $0.firstLineHeadIndent = indent + slot; $0.headIndent = indent + slot }
                let font = EditorTheme.body
                let anchor = lineStart + min(m.range.length, ns.length - 1)
                if m.range(at: 4).location != NSNotFound {
                    let mark = ns.substring(with: m.range(at: 5)).lowercased()
                    overlays.append(Overlay(kind: .checkbox(checked: mark == "x"), line: index,
                                            anchor: anchor, indent: indent, font: font))
                    if mark == "x" {
                        storage.addAttributes([.foregroundColor: UIColor.secondaryLabel],
                                              range: NSRange(location: lineStart + m.range.length,
                                                             length: ns.length - m.range.length))
                    }
                } else {
                    overlays.append(Overlay(kind: .bullet, line: index, anchor: anchor, indent: indent, font: font))
                }
                styleInline(line: ns, from: m.range.length, hide: hide)
                overlays += inlineDates(storage, line: ns, lineStart: lineStart, from: m.range.length, index: index, today: today)
                continue
            }

            // Body text sits flush with its heading's title instead of Org's indentation.
            var cursor = 0
            while cursor < ns.length, ns.character(at: cursor) == 32 || ns.character(at: cursor) == 9 { cursor += 1 }
            hide(0, cursor)
            paragraph { $0.firstLineHeadIndent = bodyIndent; $0.headIndent = bodyIndent }
            styleInline(line: ns, from: cursor, hide: hide)
            overlays += inlineDates(storage, line: ns, lineStart: lineStart, from: cursor, index: index, today: today)
        }
        return overlays
    }

    /// Hides emphasis markers and link targets, leaving the readable words.
    private static func styleInline(line: NSString, from start: Int, hide: (Int, Int) -> Void) {
        let range = NSRange(location: start, length: line.length - start)
        guard range.length > 0 else { return }
        for m in linkRegex.matches(in: line as String, range: range) {
            let shown = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            hide(m.range.location, shown.location - m.range.location)
            hide(shown.location + shown.length, m.range.location + m.range.length - shown.location - shown.length)
        }
        for m in emphasisRegex.matches(in: line as String, range: range) {
            hide(m.range.location, 1)
            hide(m.range.location + m.range.length - 1, 1)
        }
    }

    /// Active timestamps keep their (now clear) text as the room for a date chip.
    private static func inlineDates(
        _ storage: NSTextStorage, line: NSString, lineStart: Int, from start: Int, index: Int, today: OrgDate
    ) -> [Overlay] {
        OrgTimestamp.all(in: line as String).compactMap { range, timestamp in
            guard timestamp.isActive, range.location >= start else { return nil }
            let absolute = NSRange(location: lineStart + range.location, length: range.length)
            storage.addAttributes([.foregroundColor: UIColor.clear, .font: EditorTheme.small], range: absolute)
            return Overlay(kind: .inlineDate(label(for: timestamp, today: today), length: range.length),
                           line: index, anchor: absolute.location, indent: 0, font: EditorTheme.small)
        }
    }

    /// The target of the `[[target][description]]` link whose description is at `range`.
    static func linkTarget(around range: NSRange, in text: NSString) -> URL? {
        let lineRange = text.lineRange(for: range)
        let line = text.substring(with: lineRange)
        for m in linkRegex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            let match = NSRange(location: m.range.location + lineRange.location, length: m.range.length)
            guard NSIntersectionRange(match, range).length > 0 else { continue }
            let target = (line as NSString).substring(with: m.range(at: 1))
            guard let url = URL(string: target), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return url
        }
        return nil
    }

    private static func chip(for item: PlanningItem, isDone: Bool, today: OrgDate) -> Chip {
        let when = label(for: item.timestamp, today: today)
        switch item.kind {
        case .scheduled:
            return Chip(kind: .scheduled, title: when, symbol: "calendar",
                        isAlert: !isDone && item.timestamp.date < today)
        case .deadline:
            return Chip(kind: .deadline, title: "期限 \(when)", symbol: "flag.fill",
                        isAlert: !isDone && item.timestamp.date <= today)
        case .closed:
            return Chip(kind: .closed, title: "完了 \(when)", symbol: "checkmark", isAlert: false)
        }
    }

    static func label(for timestamp: OrgTimestamp, today: OrgDate) -> String {
        var text = DateLabel.short(timestamp.date, today: today)
        if let time = timestamp.time {
            text += " \(time.hour):\(String(format: "%02d", time.minute))"
        }
        if let repeater = timestamp.repeater {
            let every = ["h": "毎時間", "d": "毎日", "w": "毎週", "m": "毎月", "y": "毎年"]
            let unit = ["h": "時間", "d": "日", "w": "週", "m": "か月", "y": "年"]
            let key = repeater.unit.rawValue
            text += repeater.value == 1 ? " ・\(every[key] ?? "")" : " ・\(repeater.value)\(unit[key] ?? "")ごと"
        }
        return text
    }
}
