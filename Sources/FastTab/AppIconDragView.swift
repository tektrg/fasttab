import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An app-icon affordance that:
/// - Opens the Full Disk Access pane in System Settings on click.
/// - Vends `Bundle.main.bundleURL` as a `public.file-url` drag, so users can
///   drop it directly into the FDA list.
struct AppIconDragView: NSViewRepresentable {
    let size: CGFloat
    let onClick: () -> Void

    func makeNSView(context: Context) -> AppIconDragNSView {
        let view = AppIconDragNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: AppIconDragNSView, context: Context) {
        nsView.onClick = onClick
    }
}

final class AppIconDragNSView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?

    private let iconImageView: NSImageView
    private var mouseDownLocation: NSPoint?
    private let dragThreshold: CGFloat = 4

    override init(frame frameRect: NSRect) {
        iconImageView = NSImageView(frame: frameRect)
        iconImageView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.autoresizingMask = [.width, .height]
        super.init(frame: frameRect)
        addSubview(iconImageView)
        toolTip = "Drag into Full Disk Access, or click to open System Settings."
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard (dx * dx + dy * dy) >= (dragThreshold * dragThreshold) else { return }

        mouseDownLocation = nil
        beginAppBundleDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil else { return }
        onClick?()
    }

    private func beginAppBundleDrag(with event: NSEvent) {
        let bundleURL = Bundle.main.bundleURL as NSURL
        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL)
        let image = iconImageView.image ?? NSImage(size: bounds.size)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy, .generic, .link]
        default:
            return []
        }
    }
}
