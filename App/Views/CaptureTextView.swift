import SwiftUI
import UIKit

/// A growing text view that takes focus as soon as it is on screen, so the
/// keyboard rises together with the capture sheet like it does in Notes.
/// SwiftUI's FocusState is ignored while a sheet is still animating in.
struct CaptureTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AutoFocusTextView {
        let view = AutoFocusTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .title3)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholder.text = placeholder
        view.text = text
        view.updatePlaceholder()
        return view
    }

    func updateUIView(_ view: AutoFocusTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            view.updatePlaceholder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AutoFocusTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitting.height, 88))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CaptureTextView
        init(_ parent: CaptureTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? AutoFocusTextView)?.updatePlaceholder()
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
    }
}

final class AutoFocusTextView: UITextView {
    let placeholder = UILabel()
    private var didFocus = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.textColor = .placeholderText
        placeholder.font = .preferredFont(forTextStyle: .title3)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.widthAnchor.constraint(equalTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func updatePlaceholder() { placeholder.isHidden = !text.isEmpty }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        becomeFirstResponder()
    }
}
