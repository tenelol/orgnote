import Foundation

public struct OrgToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case headline(level: Int, done: Bool)
        case stars
        case todoKeyword
        case doneKeyword
        case priority
        case tags
        case planningKeyword
        case timestamp(active: Bool)
        case checkbox(checked: Bool)
        case listBullet
        case meta
        case comment
        case drawer
        case bold, italic, underline, strike, code
        case link
        case linkMarkup
    }

    public var range: NSRange
    public var kind: Kind
}

/// Produces highlighting tokens with UTF-16 ranges, ready for NSAttributedString.
public enum OrgSyntax {
    static let listRegex = try! NSRegularExpression(pattern: #"^([ \t]*(?:[-+]|\d+[.)])|[ \t]+\*)(?=[ \t])"#)
    static let emphasisRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])([*/_+=~])(?=\S)(.+?)(?<=\S)\1(?![\p{L}\p{N}])"#)
    static let linkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\](?:\[([^\]]+)\])?\]"#)
    static let drawerRegex = try! NSRegularExpression(pattern: #"^[ \t]*:[\w-]+:(?:[ \t]|$)"#)
    static let keywordRegex = try! NSRegularExpression(pattern: #"\b(SCHEDULED|DEADLINE|CLOSED):"#)

    public static func tokens(in text: String, keywords: OrgTodoKeywords = .default) -> [OrgToken] {
        let document = OrgDocument(text: text, defaultKeywords: keywords)
        let headlines = Dictionary(uniqueKeysWithValues: document.headlines.map { ($0.lineIndex, $0) })
        let newlineLength = (document.newline as NSString).length
        var tokens: [OrgToken] = []
        var offset = 0
        var inBlock = false

        for (index, line) in document.lines.enumerated() {
            let ns = line as NSString
            let length = ns.length
            defer { offset += length + newlineLength }
            func add(_ r: NSRange, _ kind: OrgToken.Kind) {
                tokens.append(OrgToken(range: NSRange(location: r.location + offset, length: r.length), kind: kind))
            }
            let full = NSRange(location: 0, length: length)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("#+BEGIN_") { inBlock = true; add(full, .meta); continue }
            if trimmed.uppercased().hasPrefix("#+END_") { inBlock = false; add(full, .meta); continue }
            if inBlock { add(full, .code); continue }

            if let h = headlines[index] {
                add(full, .headline(level: h.level, done: h.isDone))
                add(NSRange(location: 0, length: h.level), .stars)
                if let k = h.keywordRange { add(k, h.isDone ? .doneKeyword : .todoKeyword) }
                var base = h.keywordRange.map { $0.location + $0.length } ?? h.contentStart
                while base < length, ns.character(at: base) == 32 || ns.character(at: base) == 9 { base += 1 }
                let afterKeyword = ns.substring(from: base)
                if let p = OrgDocument.priorityRegex.firstMatch(
                    in: afterKeyword, range: NSRange(location: 0, length: (afterKeyword as NSString).length)) {
                    add(NSRange(location: base, length: p.range.length), .priority)
                }
                if let t = OrgDocument.tagsRegex.firstMatch(in: line, range: full), !h.tags.isEmpty {
                    add(t.range(at: 1), .tags)
                }
                inline(ns, from: h.contentStart, add: add)
                continue
            }

            if trimmed.hasPrefix("#+") { add(full, .meta); continue }
            if trimmed.hasPrefix("# ") || trimmed == "#" { add(full, .comment); continue }
            if drawerRegex.firstMatch(in: line, range: full) != nil { add(full, .drawer); continue }

            if OrgDocument.planningLineRegex.firstMatch(in: line, range: full) != nil {
                for m in keywordRegex.matches(in: line, range: full) { add(m.range, .planningKeyword) }
            }
            if let m = listRegex.firstMatch(in: line, range: full) { add(m.range(at: 1), .listBullet) }
            if let m = OrgDocument.checkboxRegex.firstMatch(in: line, range: full) {
                let mark = ns.substring(with: m.range(at: 1))
                add(NSRange(location: m.range(at: 1).location - 1, length: m.range(at: 1).length + 2),
                    .checkbox(checked: mark.lowercased() == "x"))
            }
            inline(ns, from: 0, add: add)
        }
        return tokens
    }

    private static func inline(_ ns: NSString, from start: Int, add: (NSRange, OrgToken.Kind) -> Void) {
        let string = ns as String
        let range = NSRange(location: start, length: ns.length - start)
        for (r, ts) in OrgTimestamp.all(in: string) where r.location >= start {
            add(r, .timestamp(active: ts.isActive))
        }
        for m in linkRegex.matches(in: string, range: range) {
            add(m.range, .linkMarkup)
            add(m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1), .link)
        }
        for m in emphasisRegex.matches(in: string, range: range) {
            let kind: OrgToken.Kind = switch ns.substring(with: m.range(at: 1)) {
            case "*": .bold
            case "/": .italic
            case "_": .underline
            case "+": .strike
            default: .code
            }
            add(m.range, kind)
        }
    }
}
