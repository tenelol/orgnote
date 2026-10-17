import Foundation
import SwiftUI

/// Renders Org inline markup for read-only text such as cards: emphasis
/// markers turn into styles, links into their descriptions, and list items
/// into bullets and check marks.
enum OrgInline {
    static func render(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += renderLine(line)
        }
        return result
    }

    private static func renderLine(_ raw: String) -> AttributedString {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var prefix = AttributedString()
        var dimmed = false
        let ns = line as NSString
        if let m = LivePreview.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 4).location != NSNotFound {
                let checked = ns.substring(with: m.range(at: 5)).lowercased() == "x"
                prefix = AttributedString(checked ? "✓ " : "○ ")
                dimmed = checked
            } else {
                let bullet = ns.substring(with: m.range(at: 2))
                prefix = AttributedString(bullet.first?.isNumber == true ? "\(bullet) " : "• ")
            }
            line = ns.substring(from: m.range.length)
        }
        var body = inline(line)
        if dimmed { body.foregroundColor = .secondary }
        return prefix + body
    }

    private static func inline(_ line: String) -> AttributedString {
        let ns = line as NSString
        var result = AttributedString()
        var cursor = 0
        var spans: [(NSRange, NSTextCheckingResult, Bool)] = []
        for m in LivePreview.linkRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            spans.append((m.range, m, true))
        }
        for m in LivePreview.emphasisRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        where !spans.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) {
            spans.append((m.range, m, false))
        }
        for (range, m, isLink) in spans.sorted(by: { $0.0.location < $1.0.location }) {
            if range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            if isLink {
                let shown = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
                var link = AttributedString(ns.substring(with: shown))
                link.foregroundColor = .accentColor
                result += link
            } else {
                var styled = AttributedString(ns.substring(with: m.range(at: 2)))
                switch ns.substring(with: m.range(at: 1)) {
                case "*": styled.inlinePresentationIntent = .stronglyEmphasized
                case "/": styled.inlinePresentationIntent = .emphasized
                case "+": styled.strikethroughStyle = .single
                case "_": styled.underlineStyle = .single
                default: styled.inlinePresentationIntent = .code
                }
                result += styled
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length { result += AttributedString(ns.substring(from: cursor)) }
        return result
    }
}
