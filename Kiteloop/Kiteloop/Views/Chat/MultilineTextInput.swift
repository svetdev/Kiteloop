import SwiftUI
import AppKit
import KiteloopCore

enum InputKeyAction {
    case historyUp
    case historyDown
    case popoverConfirm
    case popoverDismiss
    case reverseSearch
    case tabComplete
}

struct ExpandingTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var textHeight: CGFloat
    var placeholder: String = "Type a message..."
    var maxLines: Int = 4
    var onSubmit: () -> Void
    var onKeyAction: ((InputKeyAction) -> Bool)?
    /// Files pasted or dropped onto the input, for the bar to stage as attachments.
    var onAttachments: (([ChatAttachment]) -> Void)?
    /// Files pasted or dropped onto the input, for the bar to attach — or to say
    /// why it cannot — the way it does a file the paperclip picked.
    var onFileURLs: (([URL]) -> Void)?
    /// Bump to hand the cursor back to the text view, e.g. after a bar above it closes.
    var focusRequest: Int = 0

    private var lineHeight: CGFloat { 20 }
    private var maxHeight: CGFloat { lineHeight * CGFloat(maxLines) }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityIdentifier("input-text-field")
        textView.onSubmit = onSubmit
        textView.onKeyAction = onKeyAction
        textView.onAttachments = onAttachments
        textView.onFileURLs = onFileURLs

        scrollView.documentView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? InputTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight()
        }
        textView.onKeyAction = onKeyAction
        textView.onAttachments = onAttachments
        textView.onFileURLs = onFileURLs
        context.coordinator.answer(focusRequest: focusRequest)
        context.coordinator.parent = self
        context.coordinator.updatePlaceholder()
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpandingTextInput
        weak var textView: NSTextView?
        var answeredFocusRequest = 0

        init(_ parent: ExpandingTextInput) {
            self.parent = parent
        }

        /// Hands the cursor back to the text view once for each bump of
        /// `focusRequest` — after the history search above it closes — and not
        /// on the updates in between, which would pull the cursor back from
        /// wherever the person has since put it. Says whether it asked.
        @discardableResult
        func answer(focusRequest: Int) -> Bool {
            guard answeredFocusRequest != focusRequest else { return false }
            answeredFocusRequest = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalcHeight()
            updatePlaceholder()
        }

        func recalcHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }

            layoutManager.ensureLayout(for: container)
            let usedRect = layoutManager.usedRect(for: container)
            let newHeight = min(
                max(usedRect.height + textView.textContainerInset.height * 2, parent.lineHeight),
                parent.maxHeight
            )
            if abs(parent.textHeight - newHeight) > 1 {
                // Defer out of the current view-update cycle; already on main.
                Task { @MainActor in
                    self.parent.textHeight = newHeight
                }
            }
        }

        func updatePlaceholder() {
            guard let textView = textView as? InputTextView else { return }
            textView.placeholderString = parent.placeholder
            textView.needsDisplay = true
        }
    }
}

// MARK: - Custom NSTextView (handles Enter vs Shift+Enter, history, popover keys)

class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onKeyAction: ((InputKeyAction) -> Bool)?
    var onAttachments: (([ChatAttachment]) -> Void)?
    var onFileURLs: (([URL]) -> Void)?
    var placeholderString: String = "Type a message..."

    private var cursorOnFirstLine: Bool {
        guard let layoutManager, textContainer != nil else { return true }
        if string.isEmpty { return true }
        let insertionPoint = selectedRange().location
        var lineRange = NSRange(location: 0, length: 0)
        layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lineRange)
        return insertionPoint <= NSMaxRange(lineRange)
    }

    private var cursorOnLastLine: Bool {
        guard let layoutManager, textContainer != nil else { return true }
        if string.isEmpty { return true }
        let insertionPoint = selectedRange().location
        let glyphIndex = min(insertionPoint, layoutManager.numberOfGlyphs - 1)
        guard glyphIndex >= 0 else { return true }
        var lineRange = NSRange(location: 0, length: 0)
        layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        let lastGlyph = max(0, layoutManager.numberOfGlyphs - 1)
        var lastLineRange = NSRange(location: 0, length: 0)
        layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &lastLineRange)
        return lineRange.location == lastLineRange.location
    }

    override func keyDown(with event: NSEvent) {
        // While an input method is composing — kana to kanji, Pinyin, Korean —
        // Return accepts the candidate and the arrows move through the list, so
        // every key belongs to the input method until the text is committed.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if handleActionKey(event) || handleEmacsKey(event) { return }
        super.keyDown(with: event)
    }

    /// Enter, the arrows at the edge of the text, Tab, Esc and Ctrl+R: each is
    /// offered to the input bar first, and says whether it was taken.
    private func handleActionKey(_ event: NSEvent) -> Bool {
        // Enter without Shift → confirm the open popover's row, or submit
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            confirmPopoverOrSubmit()
            return true
        }
        return keyActions(for: event).contains { onKeyAction?($0) == true }
    }

    /// The actions `event` offers the input bar, in the order they are tried.
    private func keyActions(for event: NSEvent) -> [InputKeyAction] {
        // Esc — dismiss popover
        if event.keyCode == 53 { return [.popoverDismiss] }
        // Ctrl+R — reverse history search
        if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "r" {
            return [.reverseSearch]
        }
        guard !event.modifierFlags.contains(.shift) else { return [] }
        return unshiftedKeyActions(forKeyCode: event.keyCode)
    }

    /// The arrows and Tab, which offer the input bar nothing with Shift held.
    private func unshiftedKeyActions(forKeyCode keyCode: UInt16) -> [InputKeyAction] {
        switch keyCode {
        case 126 where cursorOnFirstLine:
            // Up arrow — history or popover navigation when on first line
            return [.historyUp]
        case 125 where cursorOnLastLine:
            // Down arrow — history or popover navigation when on last line
            return [.historyDown]
        case 48:
            // Tab — confirm popover selection, or trigger path completion
            return [.popoverConfirm, .tabComplete]
        default:
            return []
        }
    }

    /// Emacs keybindings (Ctrl held, no other modifiers).
    private func handleEmacsKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
            return false
        }
        switch event.charactersIgnoringModifiers {
        case "a": moveToBeginningOfLine(nil) // Ctrl+A — move to start of line
        case "e": moveToEndOfLine(nil) // Ctrl+E — move to end of line
        case "k": deleteToEndOfParagraph(nil) // Ctrl+K — delete to end of line, into the kill buffer
        case "u": deleteToBeginningOfLine(nil) // Ctrl+U — delete to start of line, into the kill buffer
        case "w": deleteWordBackward(nil) // Ctrl+W — delete word back
        default: return false
        }
        return true
    }

    /// An open slash or mention popover takes Enter to insert its highlighted
    /// row; only with none open does Enter send the message.
    private func confirmPopoverOrSubmit() {
        if onKeyAction?(.popoverConfirm) == true { return }
        onSubmit?()
    }

    // MARK: - Pasted and dropped attachments

    /// Cmd+V with files or a copied screenshot on the clipboard attaches them;
    /// anything else pastes as it always has.
    override func paste(_ sender: Any?) {
        if takeAttachments(from: .general) { return }
        super.paste(sender)
    }

    /// A file dropped on the input is attached rather than typed as its path.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeAttachments(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Hands `pasteboard`'s files, or else its pasted image, to the input bar,
    /// and says whether it held either — when it did not, the caller lets the
    /// text behaviour run. A file is handed out as its URL, even one too large
    /// or unreadable to attach, so the bar can say why rather than the path
    /// being typed into the message.
    func takeAttachments(from pasteboard: NSPasteboard) -> Bool {
        let files = Self.fileURLs(from: pasteboard)
        if !files.isEmpty {
            onFileURLs?(files)
            return true
        }
        guard let attachments = Self.attachments(from: pasteboard) else { return false }
        onAttachments?(attachments)
        return true
    }

    /// Every regular file among `pasteboard`'s URLs; a directory is skipped.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboardFileURLs(pasteboard).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// The image `pasteboard` holds when it holds no file URLs: image data
    /// carrying no text, as a single PNG. nil when it holds nothing to attach.
    static func attachments(from pasteboard: NSPasteboard) -> [ChatAttachment]? {
        guard pasteboardFileURLs(pasteboard).isEmpty else { return nil }
        return pastedImage(from: pasteboard).map { [$0] }
    }

    private static func pasteboardFileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    /// A screenshot or an image copied from another app: image data and no text
    /// to paste instead. Re-encoded as PNG, whatever the pasteboard's flavour,
    /// and fitted to the size a model accepts.
    private static func pastedImage(from pasteboard: NSPasteboard) -> ChatAttachment? {
        guard pasteboard.availableType(from: [.string]) == nil,
              let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type),
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { return nil }
        return ChatAttachment.fittedImage(filename: "Pasted image.png", data: png, mimeType: "image/png")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? .systemFont(ofSize: 14)
            ]
            let inset = textContainerInset
            let rect = NSRect(
                x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: inset.height,
                width: bounds.width,
                height: bounds.height
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }
}
