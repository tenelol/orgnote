import OrgKit
import SwiftUI
import UIKit

/// Commands from the keyboard toolbar. The document view turns them into
/// OrgDocument edits so every structural change follows the same rules.
enum EditorCommand {
    case heading
    case cycleTodo
    case checkbox
    case planning(PlanningKind, PlanningChoice)
    case priority(String?)
}

enum PlanningChoice {
    case today, tomorrow, nextWeek, pick, clear
}

/// Lets the document view drive the text view: line lookup, scrolling, focus.
@MainActor
final class EditorController {
    fileprivate weak var textView: OrgUITextView?
    var onCommand: (EditorCommand, Int) -> Void = { _, _ in }

    var currentLine: Int {
        guard let textView else { return 0 }
        let ns = textView.text as NSString
        let location = min(textView.selectedRange.location, ns.length)
        var line = 0
        var index = 0
        while index < location {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: index, length: location - index))
            if r.location == NSNotFound { break }
            line += 1
            index = r.location + 1
        }
        return line
    }

    func scroll(toLine line: Int, select: Bool = true) {
        guard let textView else { return }
        let ns = textView.text as NSString
        var location = 0
        for _ in 0..<line {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { break }
            location = r.location + 1
        }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        if select {
            var end = lineRange.location + lineRange.length
            if end > lineRange.location, ns.character(at: end - 1) == 10 { end -= 1 }
            textView.selectedRange = NSRange(location: end, length: 0)
        }
        textView.layoutIfNeeded()
        textView.scrollRangeToVisible(lineRange)
    }

    func focus() { textView?.beginEditing(at: nil) }

    /// Inserts `text` at the start of `line` (after `offset` UTF-16 units).
    func insert(_ text: String, atLine line: Int, offset: Int = 0) {
        guard let textView else { return }
        let ns = textView.text as NSString
        var location = 0
        for _ in 0..<line {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: location, length: ns.length - location))
            if r.location == NSNotFound { return }
            location = r.location + 1
        }
        textView.replace(NSRange(location: location + offset, length: 0), with: text)
        textView.delegate?.textViewDidChange?(textView)
    }
}

struct OrgTextView: UIViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    var onToggle: (OrgToggle) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> OrgUITextView {
        let view = OrgUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 120, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.font = EditorTheme.body
        view.adjustsFontForContentSizeCategory = true
        view.autocorrectionType = .default
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.dataDetectorTypes = []
        view.typingAttributes = EditorTheme.baseAttributes
        view.text = text
        view.onToggle = { toggle in context.coordinator.parent.onToggle(toggle) }
        view.inputAccessoryView = KeyboardBar(controller: controller, textView: view)
        controller.textView = view
        view.highlight()
        return view
    }

    func updateUIView(_ view: OrgUITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        guard view.markedTextRange == nil, view.text != text else { return }
        view.applyExternal(text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: OrgTextView

        init(_ parent: OrgTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? OrgUITextView else { return }
            // Re-attributing while the IME is composing breaks Japanese input.
            if view.markedTextRange == nil { view.highlight() }
            parent.onChange(view.text)
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onEditingChanged(true) }

        func textViewDidEndEditing(_ textView: UITextView) {
            textView.isEditable = false
            textView.isSelectable = false
            parent.onEditingChanged(false)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let view = textView as? OrgUITextView, !view.isReplacing else { return true }
            return !view.continueList(at: range)
        }
    }
}

enum OrgToggle {
    case checkbox(line: Int)
    case todo(line: Int)
}

final class OrgUITextView: UITextView, UIGestureRecognizerDelegate {
    var onToggle: (OrgToggle) -> Void = { _ in }
    private var toggles: [(range: NSRange, toggle: OrgToggle)] = []
    private lazy var toggleTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleToggleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        return tap
    }()

    // Like Notes, the text is read-only until tapped: a tap on a checkbox or
    // TODO keyword toggles it, a tap anywhere else starts editing right there.
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // Not selectable either: a selectable view becomes first responder on tap
        // and would raise the keyboard toolbar without actually editing.
        isEditable = false
        isSelectable = false
        addGestureRecognizer(toggleTap)
    }

    func beginEditing(at point: CGPoint?) {
        isSelectable = true
        isEditable = true
        becomeFirstResponder()
        if let point, let position = closestPosition(to: point) {
            selectedTextRange = textRange(from: position, to: position)
        }
    }

    override func accessibilityActivate() -> Bool {
        guard !isEditable else { return super.accessibilityActivate() }
        beginEditing(at: nil)
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            typingAttributes = EditorTheme.baseAttributes
            highlight()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === toggleTap else { return true }
        // While editing, plain taps belong to the text view for caret placement.
        return !isEditable || toggle(at: touch.location(in: self)) != nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // VoiceOver cannot tap a glyph, so the current line's toggles are offered as actions.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let line = line(of: selectedRange.location)
            return toggles.filter {
                switch $0.toggle {
                case let .checkbox(l), let .todo(l): l == line
                }
            }.map { entry in
                let name = switch entry.toggle {
                case .checkbox: "チェックを切り替える"
                case .todo: "完了を切り替える"
                }
                return UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    self?.onToggle(entry.toggle)
                    return true
                }
            }
        }
        set {}
    }

    @objc private func handleToggleTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        guard let toggle = toggle(at: point) else {
            if !isEditable { beginEditing(at: point) }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onToggle(toggle)
    }

    private func toggle(at point: CGPoint) -> OrgToggle? {
        guard let position = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard let hit = toggles.first(where: { $0.range.location - 1 <= offset && offset <= NSMaxRange($0.range) }) else {
            return nil
        }
        // closestPosition snaps to the nearest character, so confirm the tap is on the glyphs themselves.
        guard let start = self.position(from: beginningOfDocument, offset: hit.range.location),
              let end = self.position(from: start, offset: hit.range.length),
              let range = textRange(from: start, to: end)
        else { return nil }
        let rect = firstRect(for: range).insetBy(dx: -12, dy: -8)
        return rect.contains(point) ? hit.toggle : nil
    }

    /// Replaces only the changed span, so the caret and undo history survive
    /// edits that come from the outline, the toolbar or another device.
    func applyExternal(_ newText: String) {
        let old = text as NSString
        let new = newText as NSString
        var prefix = 0
        let maxPrefix = min(old.length, new.length)
        while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        // UITextInput moves the caret to the inserted text; keep it where the writer left it.
        let selection = selectedRange
        replace(range, with: replacement)
        guard isFirstResponder else { return }
        let delta = (replacement as NSString).length - range.length
        if selection.location >= NSMaxRange(range) {
            selectedRange = NSRange(location: selection.location + delta, length: selection.length)
        } else if selection.location < range.location {
            selectedRange = selection
        }
    }

    private(set) var isReplacing = false

    func replace(_ range: NSRange, with string: String) {
        isReplacing = true
        defer { isReplacing = false }
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end)
        else { return }
        replace(textRange, withText: string)
        highlight()
    }

    /// Continues `- [ ]` lists and plain bullets on Return; an empty item ends the list.
    func continueList(at range: NSRange) -> Bool {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
        guard let match = Self.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        let prefix = (line as NSString).substring(with: match.range)
        if (line as NSString).length == match.range.length {
            replace(NSRange(location: lineRange.location, length: match.range.length), with: "")
        } else {
            var next = prefix.replacingOccurrences(of: "[X]", with: "[ ]").replacingOccurrences(of: "[x]", with: "[ ]")
            if let number = Int(prefix.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) {
                next = next.replacingOccurrences(of: "\(number)", with: "\(number + 1)")
            }
            replace(range, with: "\n" + next)
        }
        delegate?.textViewDidChange?(self)
        return true
    }

    static let listPrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-+]|\d+[.)])[ \t]+(?:\[[ xX\-]?\][ \t]+)?"#)

    func highlight() {
        let storage = textStorage
        let selection = selectedRange
        let tokens = OrgSyntax.tokens(in: text)
        storage.beginEditing()
        EditorTheme.apply(tokens, to: storage)
        storage.endEditing()
        selectedRange = selection
        typingAttributes = EditorTheme.baseAttributes
        toggles = tokens.compactMap { token in
            switch token.kind {
            case .checkbox: (token.range, .checkbox(line: line(of: token.range.location)))
            case .todoKeyword, .doneKeyword: (token.range, .todo(line: line(of: token.range.location)))
            default: nil
            }
        }
    }

    private func line(of location: Int) -> Int {
        let ns = text as NSString
        var count = 0
        var index = 0
        while index < location {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: index, length: location - index))
            if r.location == NSNotFound { break }
            count += 1
            index = r.location + 1
        }
        return count
    }
}

/// The bar above the keyboard with Org commands for the current line.
private final class KeyboardBar: UIToolbar {
    init(controller: EditorController, textView: UITextView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        sizeToFit()

        func item(_ symbol: String, _ label: String, _ command: EditorCommand) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak controller] _ in
                guard let controller else { return }
                controller.onCommand(command, controller.currentLine)
            })
            item.accessibilityLabel = label
            return item
        }

        func planningMenu(_ kind: PlanningKind, _ symbol: String, _ label: String) -> UIBarButtonItem {
            func action(_ title: String, _ image: String, _ choice: PlanningChoice, destructive: Bool = false) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: image), attributes: destructive ? .destructive : []) {
                    [weak controller] _ in
                    guard let controller else { return }
                    controller.onCommand(.planning(kind, choice), controller.currentLine)
                }
            }
            let menu = UIMenu(title: label, children: [
                action("今日", "sun.max", .today),
                action("明日", "sunrise", .tomorrow),
                action("来週", "calendar.badge.clock", .nextWeek),
                action("日付を選択…", "calendar", .pick),
                UIMenu(options: .displayInline, children: [action("日付を外す", "xmark.circle", .clear, destructive: true)]),
            ])
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), menu: menu)
            item.accessibilityLabel = label
            return item
        }

        let priority = UIBarButtonItem(image: UIImage(systemName: "exclamationmark"), menu: UIMenu(title: "優先度", children:
            [("A", "高"), ("B", "中"), ("C", "低")].map { value, title in
                UIAction(title: "\(title)  [#\(value)]") { [weak controller] _ in
                    guard let controller else { return }
                    controller.onCommand(.priority(value), controller.currentLine)
                }
            } + [UIAction(title: "なし", attributes: .destructive) { [weak controller] _ in
                guard let controller else { return }
                controller.onCommand(.priority(nil), controller.currentLine)
            }]))
        priority.accessibilityLabel = "優先度"

        let done = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction {
            [weak textView] _ in textView?.resignFirstResponder()
        })
        done.accessibilityLabel = "キーボードを閉じる"

        items = [
            item("asterisk", "見出し", .heading),
            item("checkmark.circle", "TODOを切り替え", .cycleTodo),
            item("checklist", "チェックボックス", .checkbox),
            planningMenu(.scheduled, "calendar", "予定日"),
            planningMenu(.deadline, "flag", "期限"),
            priority,
            .flexibleSpace(),
            done,
        ]
    }

    required init?(coder: NSCoder) { fatalError() }
}
