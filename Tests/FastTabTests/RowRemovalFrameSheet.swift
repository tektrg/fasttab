import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import IndieCommandBar
@testable import FastTab

/// Frame-by-frame capture of a row being removed, old behaviour vs now:
/// `scripts/render-row-removal.sh` → `<dir>/sheet.png`. Env-gated (skipped in
/// a normal `swift test`). Draws the real shared list + Fast Tab row, and for
/// custom views the real `CustomViewPageModel` (its production 250 ms
/// debounce); the steps mirror `ContentView.performRemove`, where `old` is the
/// code before 2026-11-13 (no hide; the service's change lands 16 ms later and
/// its browser re-read 150 ms later).
@MainActor
struct RowRemovalFrameSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["ROW_REMOVAL_FRAMES_OUT"]

    enum Page: String { case recents = "Recents", custom = "Custom view" }
    enum Trigger: String { case closeButton = "close button / ←←", swipe = "trackpad swipe" }

    @MainActor
    final class Driver: ObservableObject {
        let page: Page
        let fixed: Bool
        @Published var exit = RowRemovalExit()
        @Published var recents: [BrowserSearchResult]
        @Published var pointerEdge: CommandBarSwipeEdge?
        @Published var pointerOffset: CGFloat = 0
        @Published var pointerRowID: String?
        var sources: [BrowserSearchResult]
        let changed = PassthroughSubject<Void, Never>()
        let model: CustomViewPageModel
        let store: CustomViewStore
        let viewID: UUID
        private var cancellable: AnyCancellable?

        init(page: Page, fixed: Bool, rows: [BrowserSearchResult]) {
            self.page = page
            self.fixed = fixed
            recents = rows
            sources = rows + RowRemovalFrameSheet.history
            let defaults = UserDefaults(suiteName: "test.fasttab.rowframes.\(UUID().uuidString)")!
            store = CustomViewStore(defaults: defaults)
            let view = CustomView(name: "All")
            store.add(view)
            viewID = view.id
            var getSources: () -> [BrowserSearchResult] = { [] }
            model = CustomViewPageModel(
                candidates: { getSources() },
                sourcesDidChange: changed.eraseToAnyPublisher(),
                customViewStore: store,
                emptySourcesGrace: 0
            )
            getSources = { [unowned self] in self.sources }
            cancellable = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }

        var drawn: [BrowserSearchResult] {
            let listed: [CommandBarDisplayItem] = switch page {
            case .recents: recents.map(CommandBarDisplayItem.result)
            case .custom: (model.snapshot?.items ?? []).map { .result($0.result) }
            }
            let items = fixed ? exit.visible(listed, now: Date()) : listed
            return items.compactMap { if case .result(let r) = $0 { r } else { nil } }
        }

        func remove(_ row: BrowserSearchResult) async {
            _ = exit.begin(row)
            try? await Task.sleep(for: .milliseconds(300))
            pointerRowID = nil; pointerEdge = nil; pointerOffset = 0
            withAnimation(.spring(response: 0.16, dampingFraction: 0.92)) {
                if fixed { exit.hide(row.id, now: Date()) }
                sources.removeAll { $0.id == row.id }
                changed.send()
            }
            // `BrowserTabService.results` reaches ContentView through AppState's
            // 16 ms debounced forwarding, outside the animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [self] in
                recents.removeAll { $0.id == row.id }
            }
            // `remove` then re-reads the browser's tabs (`fetchResults`); when
            // that lands it reassigns the tab cache, which restarts the custom
            // view's 250 ms debounce. 150 ms is a quick browser read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in changed.send() }
            try? await Task.sleep(for: .milliseconds(250))
            exit.finish(row.id, stillListed: drawn.contains { $0.id == row.id })
        }

        /// A trackpad swipe left to the confirm distance (~0.2 s), then the
        /// same removal (the swipe's offset continues into the exit slide).
        func swipeRemove(_ row: BrowserSearchResult) async {
            pointerRowID = row.id
            for step in 1...10 {
                pointerOffset = -ResultSwipeMetrics.confirmDistance * CGFloat(step) / 10
                pointerEdge = abs(pointerOffset) >= ResultSwipeMetrics.revealDistance ? .trailing : nil
                try? await Task.sleep(for: .milliseconds(20))
            }
            await remove(row)
        }
    }

    struct Harness: View {
        @ObservedObject var driver: Driver
        var body: some View {
            CommandBarSectionedList(sections: [CommandBarSection(id: "rows", rows: driver.drawn.map(CommandBarDisplayItem.result))]) { item, _ in
                if case .result(let result) = item {
                    SwipeableResultRow(
                        result: result,
                        isSelected: false,
                        faviconImage: nil,
                        showWindowName: false,
                        showProfileName: false,
                        pointerEdge: driver.pointerRowID == result.id ? driver.pointerEdge : nil,
                        pointerOffset: driver.pointerRowID == result.id ? driver.pointerOffset : 0,
                        keyboardEdge: nil,
                        isConfirmingRemoval: driver.exit.isExiting(result.id),
                        onHoverChange: { _ in }, onSelect: {}, onCopy: {}, onRemove: {}
                    )
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
            .background(Color(white: 0.96))
            .environment(\.colorScheme, .light)
        }
        static let size = CGSize(width: 420, height: 150)
    }

    static let rows = [
        CustomViewFilterTests.item(.tab, "https://one.example/a", title: "First tab — stays", ago: 60),
        CustomViewFilterTests.item(.tab, "https://two.example/b", title: "Second tab — REMOVED", ago: 120),
        CustomViewFilterTests.item(.tab, "https://three.example/c", title: "Third tab — stays", ago: 180),
    ]
    /// A custom view sifts every open tab, bookmark and history entry; this
    /// many older history rows give its re-evaluation a realistic cost.
    static let history = (0..<3000).map {
        CustomViewFilterTests.item(.history, "https://h\($0).example/p", title: "History \($0)", ago: TimeInterval(3600 + $0))
    }
    static let frameTimes: [Int] = Array(stride(from: 0, through: 1000, by: 50))

    /// Frames of one run, keyed by ms since the close.
    func capture(page: Page, trigger: Trigger, fixed: Bool) async throws -> [CGImage] {
        let driver = Driver(page: page, fixed: fixed, rows: Self.rows)
        if page == .custom {
            driver.model.activate(viewID: driver.viewID)
            await driver.model.refreshTask?.value
        }
        let host = NSHostingView(rootView: Harness(driver: driver))
        host.frame = NSRect(origin: .zero, size: Harness.size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let removal = Task { @MainActor in
            switch trigger {
            case .closeButton: await driver.remove(Self.rows[1])
            case .swipe: await driver.swipeRemove(Self.rows[1])
            }
        }
        var frames: [CGImage] = []
        for ms in Self.frameTimes {
            let due = start + .milliseconds(ms)
            if ContinuousClock.now < due { try await Task.sleep(until: due, clock: .continuous) }
            frames.append(try #require(Self.render(host)))
        }
        await removal.value
        return frames
    }

    static func render(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: ctx)
        return ctx.makeImage()
    }

    @Test(.enabled(if: RowRemovalFrameSheet.outDir != nil))
    func sheet() async throws {
        let outDir = try #require(Self.outDir)
        let runs: [(String, Page, Trigger)] = [
            ("Custom view · close button / ←←", .custom, .closeButton),
            ("Custom view · trackpad swipe", .custom, .swipe),
            ("Recents · close button / ←←", .recents, .closeButton),
        ]
        var columns: [(title: String, frames: [CGImage])] = []
        for (title, page, trigger) in runs {
            columns.append(("BEFORE  \(title)", try await capture(page: page, trigger: trigger, fixed: false)))
            columns.append(("AFTER  \(title)", try await capture(page: page, trigger: trigger, fixed: true)))
        }
        try Self.writeSheet(columns, to: URL(fileURLWithPath: outDir).appendingPathComponent("sheet.png"))
    }

    static func writeSheet(_ columns: [(title: String, frames: [CGImage])], to url: URL) throws {
        let frameW = Int(Harness.size.width), frameH = Int(Harness.size.height)
        let labelW = 70, headerH = 40, gap = 12
        let width = labelW + columns.count * (frameW + gap)
        let height = headerH + frameTimes.count * (frameH + 6)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black]
        for (c, column) in columns.enumerated() {
            let x = labelW + c * (frameW + gap)
            let color: NSColor = column.title.hasPrefix("BEFORE") ? .systemRed : .systemGreen
            (column.title as NSString).draw(at: NSPoint(x: x, y: 12), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: color])
            for (r, frame) in column.frames.enumerated() {
                let y = headerH + r * (frameH + 6)
                NSImage(cgImage: frame, size: NSSize(width: frameW, height: frameH))
                    .draw(in: NSRect(x: x, y: y, width: frameW, height: frameH), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        for (r, ms) in frameTimes.enumerated() {
            ("\(ms) ms" as NSString).draw(at: NSPoint(x: 8, y: headerH + r * (frameH + 6) + frameH / 2 - 8), withAttributes: font)
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
        try #require(rep?.representation(using: .png, properties: [:])).write(to: url)
    }
}
