import AppKit
import SwiftUI

/// Log output rendered by an NSTextView instead of SwiftUI `Text(…).textSelection(...)`.
/// The SwiftUI variant draws the selection in black on this panel's dark background;
/// NSTextView uses the system selection colors (readable highlight).
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        // Explicit, always-readable selection colors.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.labelColor,
        ]
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }
}
