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
        context.coordinator.lastModelText = text
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
        Self.apply(modelText: text, to: textView, coordinator: context.coordinator)
    }

    /// Writes the model's text into the box only when it is a real outside change (a cleared box after
    /// Send, a restored draft). Never while an input method is composing (marked text), and never for an
    /// echo of something the box itself reported earlier: SwiftUI hands the binding back a render late, and
    /// Vietnamese Telex tools (OpenKey) type Backspace + the accented letter faster than that, so writing
    /// the late echo back threw away what was just typed.
    ///
    /// The binding can also lag a whole key behind (live trace 2026-11-13: every key wrote the PREVIOUS
    /// text back, "s" -> "", "d" -> "s"). So only a change of the model's own value counts as outside news;
    /// a value equal to the last one seen, or one the box reported, is never written.
    static func apply(modelText text: String, to textView: AnswerTextView, coordinator: Coordinator) {
        guard text != coordinator.lastModelText else { return }
        coordinator.lastModelText = text
        if textView.hasMarkedText() {
            KeyboardDebugLog.log("binding write skipped: composing", window: textView.window)
            return
        }
        if let echo = coordinator.reported.firstIndex(of: text) {
            coordinator.reported.removeFirst(echo + 1)   // it and older echoes are used up
            if textView.string != text { KeyboardDebugLog.log("binding write skipped: late echo", window: textView.window) }
            return
        }
        guard textView.string != text else { return }
        KeyboardDebugLog.log("binding write: box \(textView.string.debugDescription) -> \(text.debugDescription)", window: textView.window)
        coordinator.reported = []
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
        /// What the box has told the binding, oldest first, until the binding echoes it back.
        var reported: [String] = []
        /// The model's value at the last render: a write happens only when it changes.
        var lastModelText = ""
        init(_ parent: MultiLineAnswerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            KeyboardDebugLog.log("box text changed to \(textView.string.debugDescription) marked=\(textView.hasMarkedText())", window: textView.window)
            reported.append(textView.string)
            if reported.count > 64 { reported.removeFirst(reported.count - 64) }
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

    /// Every card text box (answer Other, form Other, plan feedback, Message) takes the keyboard through
    /// this one path. Only a box the user can SEE does: every AgentBar window (main panel, corner card,
    /// Focus mode) draws the same model, so a hidden one builds its own copy of the box — the main panel,
    /// ordered out but still following the model, did whenever the corner card opened "Other". Its copy
    /// made the hidden panel key, and every typed key went to a window nobody could see (2026-11-12,
    /// reported three times; `CrossAppKeyboardTests`). A box also takes the keyboard back when its
    /// window becomes key or AgentBar becomes active, in case another window grabbed it in between.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers = []
        KeyboardDebugLog.log("box moved to window \(KeyboardDebugLog.describe(window))", window: window)
        guard let window else { return }
        NotificationCenter.default.post(name: Self.didAppearNotification, object: self)
        let center = NotificationCenter.default
        let reclaim: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.takeKeyboardSoon() }
        }
        keyboardObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: reclaim),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: reclaim),
        ]
        takeKeyboardSoon()
    }

    private var keyboardObservers: [NSObjectProtocol] = []

    /// Next turn of the main queue, so it lands after SwiftUI's own focus pass for the same change.
    private func takeKeyboardSoon() {
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }

    private func takeKeyboard() {
        KeyboardDebugLog.log("box take-keyboard in \(KeyboardDebugLog.describe(window)) boxFR=\(window?.firstResponder === self)", window: window)
        guard let window, window.isVisible else { return }
        // The corner card's window is `becomesKeyOnlyIfNeeded`, so a click on the "Other" ROW (not a text
        // control) leaves it non-key; the box makes it key itself.
        if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
        if window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        KeyboardDebugLog.log("box got keyDown '\(event.charactersIgnoringModifiers ?? "")'", window: window)
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

    // MARK: - Input-method trace (keyboardDebugLog flag)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        KeyboardDebugLog.log("box insertText \(String(describing: string).debugDescription) replace=\(replacementRange)", window: window)
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        KeyboardDebugLog.log("box setMarkedText \(String(describing: string).debugDescription) replace=\(replacementRange)", window: window)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        KeyboardDebugLog.log("box unmarkText", window: window)
        super.unmarkText()
    }

    override func deleteBackward(_ sender: Any?) {
        KeyboardDebugLog.log("box deleteBackward", window: window)
        super.deleteBackward(sender)
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
