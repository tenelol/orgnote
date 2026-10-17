import OrgKit
import UIKit

/// Maps Org syntax to text attributes. Markup stays visible (the file is the
/// source of truth for Neovim), but it recedes so the writing reads like a note.
enum EditorTheme {
    static var body: UIFont { .preferredFont(forTextStyle: .body) }

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
    }

    static func headlineFont(_ level: Int) -> UIFont {
        switch level {
        case 1: font(.title2, weight: .bold)
        case 2: font(.title3, weight: .semibold)
        default: font(.body, weight: .semibold)
        }
    }

    static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    static var mono: UIFont {
        UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    }

    static var small: UIFont { .preferredFont(forTextStyle: .footnote) }

    /// systemOrange is too light on white for text; a deeper orange keeps 4.5:1.
    static let todoColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemOrange
            : UIColor(red: 0.70, green: 0.28, blue: 0.0, alpha: 1)
    }

    static func apply(_ tokens: [OrgToken], to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(baseAttributes, range: full)

        for token in tokens {
            let range = NSIntersectionRange(token.range, full)
            guard range.length > 0 else { continue }
            switch token.kind {
            case let .headline(level, done):
                let headlineStyle = NSMutableParagraphStyle()
                headlineStyle.setParagraphStyle(paragraph)
                headlineStyle.paragraphSpacingBefore = level == 1 ? 10 : 6
                storage.addAttributes([.font: headlineFont(level), .paragraphStyle: headlineStyle], range: range)
                if done {
                    storage.addAttributes([
                        .foregroundColor: UIColor.secondaryLabel,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: UIColor.tertiaryLabel,
                    ], range: range)
                }
            case .stars:
                storage.addAttributes([.foregroundColor: UIColor.tertiaryLabel, .strikethroughStyle: 0], range: range)
            case .todoKeyword:
                storage.addAttributes([.foregroundColor: todoColor, .strikethroughStyle: 0], range: range)
                addWeight(.heavy, to: range, in: storage)
            case .doneKeyword:
                storage.addAttributes([.foregroundColor: UIColor.tintColor, .strikethroughStyle: 0], range: range)
                addWeight(.heavy, to: range, in: storage)
            case .priority:
                storage.addAttributes([.foregroundColor: UIColor.systemRed], range: range)
            case .tags:
                storage.addAttributes([.foregroundColor: UIColor.secondaryLabel, .font: small], range: range)
            case .planningKeyword:
                storage.addAttributes([.foregroundColor: UIColor.secondaryLabel, .font: font(.caption1, weight: .semibold)], range: range)
            case let .timestamp(active):
                storage.addAttributes([
                    .foregroundColor: active ? UIColor.tintColor : UIColor.secondaryLabel,
                    .font: UIFont.monospacedDigitSystemFont(ofSize: small.pointSize, weight: .medium),
                ], range: range)
            case let .checkbox(checked):
                // Green means done everywhere in the app; an open box stays neutral.
                storage.addAttributes([
                    .foregroundColor: checked ? UIColor.tintColor : UIColor.secondaryLabel,
                    .font: UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: .bold),
                ], range: range)
            case .listBullet:
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
            case .meta, .drawer:
                storage.addAttributes([.foregroundColor: UIColor.secondaryLabel, .font: small], range: range)
            case .comment:
                storage.addAttributes([.foregroundColor: UIColor.tertiaryLabel, .font: small], range: range)
            case .bold:
                addWeight(.bold, to: range, in: storage)
            case .italic:
                addTrait(.traitItalic, to: range, in: storage)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code:
                storage.addAttributes([.font: mono, .backgroundColor: UIColor.secondarySystemFill], range: range)
            case .link:
                storage.addAttributes([.foregroundColor: UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            case .linkMarkup:
                storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: range)
            }
        }
    }

    private static func addWeight(_ weight: UIFont.Weight, to range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let size = (value as? UIFont)?.pointSize ?? body.pointSize
            storage.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: weight), range: subrange)
        }
    }

    private static func addTrait(_ trait: UIFontDescriptor.SymbolicTraits, to range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? UIFont) ?? body
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return }
            storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: subrange)
        }
    }
}
