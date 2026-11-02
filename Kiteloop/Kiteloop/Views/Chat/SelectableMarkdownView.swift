import AppKit
import Highlightr
import SwiftUI

struct SelectableMarkdownView: NSViewRepresentable {
    let markdown: String
    /// Set in the terminal look: every run of the rendered reply is monospaced.
    var monospaced = false
    /// Set on a chat row's reply: the text's right-click menu offers Branch from Here.
    var onBranchFromHere: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectableTextHost {
        let host = SelectableTextHost()
        context.coordinator.host = host
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastColorScheme = colorScheme
        host.onBranchFromHere = onBranchFromHere
        host.setContent(rendered())
        return host
    }

    func updateNSView(_ host: SelectableTextHost, context: Context) {
        host.onBranchFromHere = onBranchFromHere
        if context.coordinator.lastMarkdown != markdown || context.coordinator.lastColorScheme != colorScheme {
            context.coordinator.lastMarkdown = markdown
            context.coordinator.lastColorScheme = colorScheme
            host.setContent(rendered())
        }
    }

    private func rendered() -> NSAttributedString {
        let text = MarkdownRenderer.render(markdown, isDark: colorScheme == .dark)
        return monospaced ? TerminalStyle.monospaced(text) : text
    }

    class Coordinator {
        weak var host: SelectableTextHost?
        var lastMarkdown: String = ""
        var lastColorScheme: ColorScheme = .dark
    }

}

// MARK: - NSView host that auto-sizes its height

final class NonScrollingTextView: NSTextView {
    /// Branches the conversation at this text's message; nil leaves the menu without it.
    var onBranchFromHere: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    /// Right-clicking inside a rendered code block adds "Copy Code" on top of the
    /// default menu, and a chat reply adds "Branch from Here" below it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = addingBranchFromHere(to: super.menu(for: event))
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard let layoutManager, let textContainer, let storage = textStorage else { return menu }
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let code = MarkdownRenderer.codeBlock(in: storage, at: index) else { return menu }
        let item = NSMenuItem(title: "Copy Code", action: #selector(copyCode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = code
        let result = menu ?? NSMenu()
        result.insertItem(item, at: 0)
        if result.items.count > 1 { result.insertItem(.separator(), at: 1) }
        return result
    }

    private func addingBranchFromHere(to menu: NSMenu?) -> NSMenu? {
        guard onBranchFromHere != nil else { return menu }
        let item = NSMenuItem(title: "Branch from Here", action: #selector(branchFromHere(_:)), keyEquivalent: "")
        item.target = self
        let result = menu ?? NSMenu()
        result.insertItem(item, at: 0)
        if result.items.count > 1 { result.insertItem(.separator(), at: 1) }
        return result
    }

    @objc private func branchFromHere(_ sender: NSMenuItem) {
        onBranchFromHere?()
    }

    @objc private func copyCode(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

final class SelectableTextHost: NSView {
    private let textView: NonScrollingTextView
    private let textContainer: NSTextContainer
    private let layoutManager: NSLayoutManager
    private let textStorage: NSTextStorage

    var onBranchFromHere: (() -> Void)? {
        get { textView.onBranchFromHere }
        set { textView.onBranchFromHere = newValue }
    }

    override init(frame: NSRect) {
        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        textView = NonScrollingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand
        ]

        super.init(frame: frame)
        addSubview(textView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local) {
            return textView
        }
        return nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ attributedString: NSAttributedString) {
        textStorage.setAttributedString(attributedString)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        textContainer.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 20) }
        textContainer.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height) + 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateIntrinsicContentSize()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        invalidateIntrinsicContentSize()
    }
}
