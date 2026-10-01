import AppKit
import SwiftUI

/// The free-text answer box: Return sends, Shift+Return (or Option+Return) adds a
/// line, Escape goes back to the options. A plain text view rather than SwiftUI's
/// `TextEditor`, whose Return handling cannot be told apart from Shift+Return.
struct MultiLineAnswerField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onLeave: () -> Void
    var onLeaveUp: () -> Void = {}
    var onLeaveDown: () -> Void = {}
    /// Set by boxes that take images (the message card): ⌘V / drop of an image goes here instead of the text.
    var onImages: (([NSImage]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AnswerTextView()
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onLeave = { context.coordinator.parent.onLeave() }
        textView.onLeaveUp = { context.coordinator.parent.onLeaveUp() }
        textView.onLeaveDown = { context.coordinator.parent.onLeaveDown() }
        syncImageHandler(textView, context: context)
        textView.delegate = context.coordinator
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))   // typing continues where it was left
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? AnswerTextView else { return }
        syncImageHandler(textView, context: context)
        guard textView.string != text else { return }
        textView.string = text
    }

    /// The view can outlive a card (SwiftUI reuses it): images go to the current `onImages`, and with none an
    /// image paste falls through to plain text paste instead of vanishing.
    private func syncImageHandler(_ textView: AnswerTextView, context: Context) {
        textView.onImages = onImages == nil ? nil : { context.coordinator.parent.onImages?($0) }
        let imageDragTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .fileURL]
        if onImages != nil, !Set(imageDragTypes).isSubset(of: textView.registeredDraggedTypes) {
            textView.registerForDraggedTypes(textView.registeredDraggedTypes + imageDragTypes)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineAnswerField
        init(_ parent: MultiLineAnswerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// The text view behind `MultiLineAnswerField`: takes the keyboard when it appears
/// and tells its owner what Return and Escape mean.
final class AnswerTextView: NSTextView {
    static let returnKeyCodes: Set<UInt16> = [36, 76]   // Return, keypad Enter
    static let escapeKeyCode: UInt16 = 53

    var onSubmit: () -> Void = {}
    var onLeave: () -> Void = {}
    /// ↑ with the caret on the first line, ↓ with it on the last: the text stays, the owner moves to the options.
    var onLeaveUp: () -> Void = {}
    var onLeaveDown: () -> Void = {}
    /// Nil: pastes and drops behave as plain text (answer cards).
    var onImages: (([NSImage]) -> Void)?
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125

    /// A text view with its own text system (a bare `init` leaves it without one, and text goes nowhere).
    convenience init() {
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 60), textContainer: container)
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: 0, height: 2)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Posted when a card text box enters a window: the panel controller uses it to make AgentBar
    /// the frontmost app while one is on screen (`TextInputActivation`), so dictation tools can type into it.
    static let didAppearNotification = Notification.Name("AgentBar.AnswerTextView.didAppear")

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.post(name: Self.didAppearNotification, object: self)
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        if Self.returnKeyCodes.contains(event.keyCode) {
            // A held Return would send text the moment the box opens (Return on the row opened it), before it is read.
            if event.isARepeat { return }
            if event.modifierFlags.intersection([.shift, .option]).isEmpty { onSubmit() } else { insertNewlineIgnoringFieldEditor(nil) }
            return
        }
        if event.keyCode == Self.escapeKeyCode {
            onLeave()
            return
        }
        if event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty, selectedRange().length == 0 {
            if event.keyCode == Self.upArrowKeyCode, caretIsOnFirstLine { onLeaveUp(); return }
            if event.keyCode == Self.downArrowKeyCode, caretIsOnLastLine { onLeaveDown(); return }
        }
        super.keyDown(with: event)
    }

    // MARK: - Images

    override func paste(_ sender: Any?) {
        if takeImages(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onImages != nil, MessageImage.pasteboardHasImage(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onImages != nil, MessageImage.pasteboardHasImage(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if takeImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// True when the pasteboard held images and they went to `onImages` (the text is left alone).
    private func takeImages(from pasteboard: NSPasteboard) -> Bool {
        guard let onImages else { return false }
        let images = MessageImage.images(from: pasteboard)
        guard !images.isEmpty else { return false }
        onImages(images)
        return true
    }

    // MARK: - Where the caret is

    /// The line (as wrapped on screen) the caret is on, as an index among the text's lines.
    private func caretLineIndex() -> (index: Int, count: Int) {
        guard let layoutManager, let textContainer else { return (0, 1) }
        layoutManager.ensureLayout(for: textContainer)
        let length = (string as NSString).length
        var lineStarts: [Int] = []
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            lineStarts.append(layoutManager.characterIndexForGlyph(at: range.location))
            glyph = NSMaxRange(range)
        }
        if lineStarts.isEmpty || string.hasSuffix("\n") { lineStarts.append(length) }   // the empty line after a final break
        let caret = selectedRange().location
        let index = lineStarts.lastIndex { $0 <= caret } ?? 0
        return (index, lineStarts.count)
    }

    var caretIsOnFirstLine: Bool { caretLineIndex().index == 0 }

    var caretIsOnLastLine: Bool {
        let position = caretLineIndex()
        return position.index == position.count - 1
    }
}
