import OrgKit
import SwiftUI
import UIKit

/// Commands from the keyboard toolbar. The document view turns them into
/// OrgDocument edits so every structural change follows the same rules.
enum EditorCommand {
    /// Makes the line a headline of this level, or body text for nil.
    case heading(level: Int?)
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
}

struct OrgTextView: UIViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    var onToggle: (OrgToggle) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    var livePreview = true
    /// Capture mode: start typing as soon as the view appears, show a
    /// placeholder, and set a plain first line as the title.
    var capture: CaptureStyle?
    let controller: EditorController

    struct CaptureStyle {
        var placeholder: String
    }

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
        view.onCommand = { [weak controller] command, line in controller?.onCommand(command, line) }
        view.livePreview = livePreview
        if let capture {
            view.autoFocus = true
            view.emphasizesFirstLine = true
            view.placeholder.text = capture.placeholder
            view.textContainerInset = UIEdgeInsets(top: 8, left: 20, bottom: 16, right: 20)
        }
        view.inputAccessoryView = KeyboardBar(controller: controller, textView: view)
        controller.textView = view
        view.highlight()
        return view
    }

    func updateUIView(_ view: OrgUITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view
        if view.livePreview != livePreview {
            view.livePreview = livePreview
            view.highlight()
        }
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
            view.updatePlaceholder()
            parent.onChange(view.text)
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onEditingChanged(true) }

        func textViewDidEndEditing(_ textView: UITextView) {
            textView.isEditable = false
            textView.isSelectable = false
            (textView as? OrgUITextView)?.updateRevealedLines()
            parent.onEditingChanged(false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? OrgUITextView)?.updateRevealedLines()
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
    case link(URL)
}

final class OrgUITextView: UITextView, UIGestureRecognizerDelegate {
    var onToggle: (OrgToggle) -> Void = { _ in }
    var onCommand: (EditorCommand, Int) -> Void = { _, _ in }
    var livePreview = true
    /// Lines shown as raw Org because the caret is on them.
    private var revealed: Set<Int> = []
    private var overlays: [LivePreview.Overlay] = []
    private var overlayViews: [UIView] = []
    private var laidOutWidth: CGFloat = 0
    var autoFocus = false
    var emphasizesFirstLine = false
    let placeholder = UILabel()

    func updatePlaceholder() {
        placeholder.isHidden = !text.isEmpty
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, autoFocus else { return }
        autoFocus = false
        // Focusing in the same pass as the sheet's appearance raises the keyboard with it.
        beginEditing(at: nil)
    }
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
        placeholder.font = EditorTheme.headlineFont(1)
        placeholder.textColor = .placeholderText
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)
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
        // Checkbox and chip overlays handle their own taps.
        if touch.view is UIControl { return false }
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
                case .link: false
                }
            }.map { entry in
                let name = switch entry.toggle {
                case .checkbox: String(localized: "Toggle Checkbox")
                case .todo, .link: String(localized: "Toggle Done")
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
        guard let hit = toggles.first(where: { entry in
            // While editing, a tap on a link should place the caret, not leave the app.
            if case .link = entry.toggle, isEditable { return false }
            return entry.range.location - 1 <= offset && offset <= NSMaxRange(entry.range)
        }) else {
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
        if selection.location > NSMaxRange(range) {
            selectedRange = NSRange(location: selection.location + delta, length: selection.length)
        } else if selection.location < range.location {
            selectedRange = selection
        } else {
            // Inside the change: stay on the same line, as far from its end as before.
            // Commands rewrite a line's start (stars, keyword) and add lines below it,
            // so following the offset would land the caret in what was added.
            let line = old.substring(to: selection.location).components(separatedBy: "\n").count - 1
            var end = 0
            old.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: selection.location, length: 0))
            let fromEnd = end - selection.location
            let lines = (text as NSString).components(separatedBy: "\n")
            guard line < lines.count else { return }
            let start = lines[..<line].reduce(0) { $0 + ($1 as NSString).length + 1 }
            let length = (lines[line] as NSString).length
            selectedRange = NSRange(location: start + max(0, length - fromEnd), length: 0)
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
        let document = OrgDocument(text: text)
        overlays = livePreview
            ? LivePreview.apply(to: storage, document: document, revealed: revealed)
            : []
        // In capture, a plain first line becomes the entry's headline, so it looks like one.
        if emphasizesFirstLine, document.headline(at: 0) == nil, let first = document.lines.first, !first.isEmpty {
            storage.addAttribute(.font, value: EditorTheme.headlineFont(1),
                                 range: NSRange(location: 0, length: (first as NSString).length))
        }
        storage.endEditing()
        selectedRange = selection
        typingAttributes = EditorTheme.baseAttributes
        if emphasizesFirstLine, line(of: selection.location) == 0, document.headline(at: 0) == nil {
            typingAttributes[.font] = EditorTheme.headlineFont(1)
        }
        let ns = text as NSString
        toggles = tokens.compactMap { token in
            switch token.kind {
            case .checkbox: (token.range, .checkbox(line: line(of: token.range.location)))
            case .todoKeyword, .doneKeyword: (token.range, .todo(line: line(of: token.range.location)))
            case .link:
                LivePreview.linkTarget(around: token.range, in: ns).map { (token.range, .link($0)) }
            default: nil
            }
        }
        layoutOverlays()
    }

    /// Reveals the raw Org of the lines under the caret while editing.
    func updateRevealedLines() {
        guard markedTextRange == nil else { return }
        var lines: Set<Int> = []
        if isFirstResponder, isEditable {
            let first = line(of: selectedRange.location)
            let last = line(of: selectedRange.location + selectedRange.length)
            lines = Set(first...max(first, last))
        }
        guard lines != revealed else { return }
        revealed = lines
        highlight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.sizeToFit()
        placeholder.frame.origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        if bounds.width != laidOutWidth { layoutOverlays() }
    }

    // MARK: Overlays

    private func layoutOverlays() {
        overlayViews.forEach { $0.removeFromSuperview() }
        overlayViews = []
        laidOutWidth = bounds.width
        guard !overlays.isEmpty, let layout = textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        for overlay in overlays {
            guard let frames = fragmentFrames(at: overlay.anchor, in: layout),
                  let view = makeOverlay(overlay, frames: frames)
            else { continue }
            addSubview(view)
            overlayViews.append(view)
        }
    }

    /// The paragraph's frame and its first line's frame, in this view's coordinates.
    private func fragmentFrames(at offset: Int, in layout: NSTextLayoutManager) -> (paragraph: CGRect, line: CGRect)? {
        guard let location = layout.location(layout.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location)
        else { return nil }
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        let line = fragment.textLineFragments.first?.typographicBounds ?? CGRect(origin: .zero, size: frame.size)
        return (frame, line.offsetBy(dx: frame.minX, dy: frame.minY))
    }

    private func makeOverlay(_ overlay: LivePreview.Overlay, frames: (paragraph: CGRect, line: CGRect)) -> UIView? {
        let left = textContainerInset.left + overlay.indent
        switch overlay.kind {
        case let .todo(done), let .checkbox(done):
            let isTask: Bool = if case .todo = overlay.kind { true } else { false }
            let size = min(max(overlay.font.pointSize * (isTask ? 0.9 : 1.0), 17), 22)
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: done ? "checkmark.circle.fill" : "circle",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)),
                            for: .normal)
            button.tintColor = done ? .tintColor : .secondaryLabel
            button.frame = CGRect(x: left + LivePreview.slot / 2 - 22, y: frames.line.midY - 22, width: 44, height: 44)
            button.accessibilityLabel = done ? String(localized: "Done") : String(localized: "Not Done")
            button.accessibilityHint = done ? String(localized: "Marks as not done.") : String(localized: "Marks as done.")
            let toggle: OrgToggle = isTask ? .todo(line: headlineLine(for: overlay.line)) : .checkbox(line: overlay.line)
            button.addAction(UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.onToggle(toggle)
            }, for: .primaryActionTriggered)
            return button
        case .bullet:
            let dot = UIView(frame: CGRect(x: left + LivePreview.slot / 2 - 3, y: frames.line.midY - 3, width: 6, height: 6))
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3
            dot.isUserInteractionEnabled = false
            return dot
        case let .planning(chips):
            let stack = UIStackView(arrangedSubviews: chips.map { chipButton($0, line: overlay.line) })
            stack.axis = .horizontal
            stack.spacing = 6
            let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            stack.frame = CGRect(x: left, y: frames.paragraph.midY - size.height / 2, width: size.width, height: size.height)
            return stack
        case let .timestamp(label):
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))
            config.imagePadding = 4
            config.contentInsets = .zero
            config.attributedTitle = AttributedString(label, attributes: AttributeContainer([.font: EditorTheme.small]))
            config.baseForegroundColor = .secondaryLabel
            let button = UIButton(configuration: config)
            button.isUserInteractionEnabled = false
            button.sizeToFit()
            button.frame.origin = CGPoint(x: left, y: frames.paragraph.midY - button.bounds.height / 2)
            return button
        case let .inlineDate(title, length):
            guard let start = position(from: beginningOfDocument, offset: overlay.anchor),
                  let end = position(from: start, offset: length),
                  let range = textRange(from: start, to: end)
            else { return nil }
            let rect = firstRect(for: range)
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .capsule
            config.image = UIImage(systemName: "calendar", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2))
            config.imagePadding = 3
            config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: EditorTheme.small]))
            config.baseForegroundColor = .tintColor
            let chip = UIButton(configuration: config)
            chip.isUserInteractionEnabled = false
            chip.sizeToFit()
            chip.frame.origin = CGPoint(x: rect.minX, y: rect.midY - chip.bounds.height / 2)
            return chip
        case let .priority(marks):
            let label = UILabel()
            label.text = marks
            label.font = UIFont.systemFont(ofSize: overlay.font.pointSize, weight: .heavy)
            label.textColor = .systemRed
            label.sizeToFit()
            guard let start = position(from: beginningOfDocument, offset: overlay.anchor),
                  let end = position(from: start, offset: 1),
                  let range = textRange(from: start, to: end)
            else { return nil }
            let rect = firstRect(for: range)
            label.frame.origin = CGPoint(x: rect.minX, y: frames.line.midY - label.bounds.height / 2)
            label.accessibilityLabel = String(localized: "Priority")
            return label
        }
    }

    private func chipButton(_ chip: LivePreview.Chip, line: Int) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: chip.symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        config.attributedTitle = AttributedString(
            chip.title, attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .footnote)]))
        config.baseForegroundColor = chip.isAlert ? .systemRed : (chip.kind == .closed ? .secondaryLabel : .tintColor)
        let button = UIButton(configuration: config)
        guard chip.kind != .closed else {
            button.isUserInteractionEnabled = false
            return button
        }
        func action(_ title: LocalizedStringResource, _ image: String, _ choice: PlanningChoice, destructive: Bool = false) -> UIAction {
            UIAction(title: String(localized: title), image: UIImage(systemName: image), attributes: destructive ? .destructive : []) {
                [weak self] _ in self?.onCommand(.planning(chip.kind, choice), line)
            }
        }
        button.menu = UIMenu(title: chip.kind == .deadline ? String(localized: "Deadline") : String(localized: "Schedule"), children: [
            action("Today", "sun.max", .today),
            action("Tomorrow", "sunrise", .tomorrow),
            action("Next Week", "calendar.badge.clock", .nextWeek),
            action("Choose Date…", "calendar", .pick),
            UIMenu(options: .displayInline, children: [action("Remove Date", "xmark.circle", .clear, destructive: true)]),
        ])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityHint = String(localized: "Changes the date.")
        return button
    }

    /// TODO overlays sit on the headline line itself.
    private func headlineLine(for line: Int) -> Int { line }

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

/// The bar above the keyboard with Org commands for the current line. Buttons
/// share the width equally, so the bar always fits the screen.
private final class KeyboardBar: UIView {
    init(controller: EditorController, textView: UITextView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        autoresizingMask = .flexibleHeight

        func button(_ label: LocalizedStringResource, symbol: String? = nil, title: String? = nil) -> UIButton {
            var config = UIButton.Configuration.plain()
            if let symbol {
                config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            }
            if let title {
                config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                    .font: UIFont.systemFont(ofSize: 13, weight: .heavy),
                ]))
            }
            config.baseForegroundColor = .label
            config.contentInsets = .zero
            let button = UIButton(configuration: config)
            button.accessibilityLabel = String(localized: label)
            return button
        }

        func command(_ label: LocalizedStringResource, symbol: String? = nil, title: String? = nil, _ command: EditorCommand) -> UIButton {
            let b = button(label, symbol: symbol, title: title)
            b.addAction(UIAction { [weak controller, weak textView] _ in
                guard let controller else { return }
                // Commit any in-progress IME composition first, or the edit would be dropped.
                textView?.unmarkText()
                controller.onCommand(command, controller.currentLine)
            }, for: .primaryActionTriggered)
            return b
        }

        func menu(_ label: LocalizedStringResource, symbol: String, _ menu: UIMenu) -> UIButton {
            let b = button(label, symbol: symbol)
            b.menu = menu
            b.showsMenuAsPrimaryAction = true
            return b
        }

        func planningMenu(_ kind: PlanningKind, _ label: LocalizedStringResource) -> UIMenu {
            func action(_ title: LocalizedStringResource, _ image: String, _ choice: PlanningChoice, destructive: Bool = false) -> UIAction {
                UIAction(title: String(localized: title), image: UIImage(systemName: image), attributes: destructive ? .destructive : []) {
                    [weak controller, weak textView] _ in
                    guard let controller else { return }
                // Commit any in-progress IME composition first, or the edit would be dropped.
                textView?.unmarkText()
                    controller.onCommand(.planning(kind, choice), controller.currentLine)
                }
            }
            return UIMenu(title: String(localized: label), children: [
                action("Today", "sun.max", .today),
                action("Tomorrow", "sunrise", .tomorrow),
                action("Next Week", "calendar.badge.clock", .nextWeek),
                action("Choose Date…", "calendar", .pick),
                UIMenu(options: .displayInline, children: [action("Remove Date", "xmark.circle", .clear, destructive: true)]),
            ])
        }

        let priority = UIMenu(title: String(localized: "Priority"), children:
            [("A", String(localized: "High")), ("B", String(localized: "Medium")), ("C", String(localized: "Low"))].map { value, title in
                UIAction(title: "\(title)  [#\(value)]") { [weak controller, weak textView] _ in
                    guard let controller else { return }
                    // Commit any in-progress IME composition first, or the edit would be dropped.
                    textView?.unmarkText()
                    controller.onCommand(.priority(value), controller.currentLine)
                }
            } + [UIAction(title: String(localized: "None"), attributes: .destructive) { [weak controller, weak textView] _ in
                guard let controller else { return }
                // Commit any in-progress IME composition first, or the edit would be dropped.
                textView?.unmarkText()
                controller.onCommand(.priority(nil), controller.currentLine)
            }])

        // Built on each open, so the line's current level carries the checkmark.
        // UIKit calls the provider on the main thread, though the SDK leaves it nonisolated.
        let heading = UIMenu(title: String(localized: "Heading"), children: [UIDeferredMenuElement.uncached { [weak controller, weak textView] completion in
            MainActor.assumeIsolated {
                let current = textView.flatMap { view in controller.map { Self.headingLevel(in: view.text, line: $0.currentLine) } } ?? nil
                @MainActor func action(_ title: LocalizedStringResource, _ level: Int?) -> UIAction {
                    let action = UIAction(title: String(localized: title)) { [weak controller, weak textView] _ in
                        guard let controller else { return }
                        // Commit any in-progress IME composition first, or the edit would be dropped.
                        textView?.unmarkText()
                        controller.onCommand(.heading(level: level), controller.currentLine)
                    }
                    action.state = current == level ? .on : .off
                    return action
                }
                completion([
                    UIMenu(options: .displayInline, children: [action("Heading 1", 1), action("Heading 2", 2), action("Heading 3", 3)]),
                    action("Body Text", nil),
                ])
            }
        }])

        let stack = UIStackView(arrangedSubviews: [
            menu("Heading", symbol: "asterisk", heading),
            command("Toggle To-do", title: "TODO", .cycleTodo),
            command("Checkbox", symbol: "checklist", .checkbox),
            menu("Schedule", symbol: "calendar", planningMenu(.scheduled, "Schedule")),
            menu("Deadline", symbol: "flag", planningMenu(.deadline, "Deadline")),
            menu("Priority", symbol: "exclamationmark", priority),
        ])
        stack.distribution = .fillEqually

        let commands = UIVisualEffectView(effect: UIGlassEffect())
        commands.cornerConfiguration = .capsule()
        commands.contentView.addSubview(stack)

        let dismiss = button("Hide Keyboard", symbol: "keyboard.chevron.compact.down")
        dismiss.addAction(UIAction { [weak textView] _ in textView?.resignFirstResponder() }, for: .primaryActionTriggered)
        let dismissGlass = UIVisualEffectView(effect: UIGlassEffect())
        dismissGlass.cornerConfiguration = .capsule()
        dismissGlass.contentView.addSubview(dismiss)

        for view in [commands, dismissGlass, stack, dismiss] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(commands)
        addSubview(dismissGlass)
        NSLayoutConstraint.activate([
            commands.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            commands.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            commands.heightAnchor.constraint(equalToConstant: 46),
            dismissGlass.leadingAnchor.constraint(equalTo: commands.trailingAnchor, constant: 8),
            dismissGlass.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            dismissGlass.centerYAnchor.constraint(equalTo: commands.centerYAnchor),
            dismissGlass.widthAnchor.constraint(equalToConstant: 46),
            dismissGlass.heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: commands.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: commands.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: commands.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: commands.contentView.bottomAnchor),
            dismiss.leadingAnchor.constraint(equalTo: dismissGlass.contentView.leadingAnchor),
            dismiss.trailingAnchor.constraint(equalTo: dismissGlass.contentView.trailingAnchor),
            dismiss.topAnchor.constraint(equalTo: dismissGlass.contentView.topAnchor),
            dismiss.bottomAnchor.constraint(equalTo: dismissGlass.contentView.bottomAnchor),
        ])
    }

    /// The headline level of `line`: its stars, when a space or the line's end follows them.
    static func headingLevel(in text: String, line: Int) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard line < lines.count else { return nil }
        let stars = lines[line].prefix { $0 == "*" }.count
        guard stars > 0 else { return nil }
        let next = lines[line].dropFirst(stars).first
        return next == nil || next == " " || next == "\t" ? stars : nil
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 56) }

    required init?(coder: NSCoder) { fatalError() }
}
