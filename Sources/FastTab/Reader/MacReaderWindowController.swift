import AppKit
import FastTabReader
import FastTabSync
import SwiftUI

/// What the reader window shows.
enum MacReaderContent: Equatable {
    case loading
    case article(html: String, baseURL: URL)
    case failed
}

/// One article's reader: fetches it (cache first, else Readability), shows it, and writes the
/// scroll position back to the FastTab List.
@MainActor
final class MacReaderModel: ObservableObject {
    @Published private(set) var content: MacReaderContent = .loading
    @Published private(set) var title: String

    let url: URL
    let progressSink: MacReaderProgressSink
    private let cache = MacReaderArticleCache(directory: MacReaderArticleCache.defaultDirectory)

    /// Counts a reread (read count) once the page has loaded with its starting position.
    private let readSession: MacReadSessionTracker

    init(url: URL, title: String?) {
        self.url = url
        self.title = title ?? url.host() ?? url.absoluteString
        let urlString = url.absoluteString
        let readSession = MacReadSessionTracker()
        self.readSession = readSession
        progressSink = MacReaderProgressSink { progress in
            FastTabListStore.shared.recordReaderProgress(
                url: urlString, progress: progress, finishedRead: readSession.record(progress: progress))
        }
    }

    func load() async {
        let urlString = url.absoluteString
        var article = cache.article(forURL: urlString)
        if article == nil {
            article = try? await MacReaderExtractor.extract(url: url)
            if let article { cache.store(article, forURL: urlString) }
        }
        guard let article, let template = MacReaderResources.readerTemplateHTML else {
            content = .failed
            return
        }
        if !article.title.isEmpty { title = article.title }
        let supportDirectory = SyncService.shared.fastTabSupportDirectory
        let synced = ReaderMirror.loadHighlights(in: ReaderMirror.directory(supportDirectory: supportDirectory))
        let progress = FastTabListStore.shared.item(id: FastTabListLibrary.itemID(for: urlString)).map(\.progress) ?? 0
        readSession.begin(startProgress: progress)
        let html = MacReaderPage.html(template: template, article: article, initialProgress: progress,
                                      highlights: MacReaderPage.highlights(forURL: urlString, in: synced))
        content = .article(html: html, baseURL: article.url)
    }

    func openInBrowser() {
        progressSink.flush()
        AppState.shared.browserService.openFastTabListItemInBrowser(url: url.absoluteString, title: title)
    }
}

/// A normal, resizable window holding one article.
@MainActor
final class MacReaderWindowController: NSWindowController, NSWindowDelegate {
    private let model: MacReaderModel
    private let onClose: () -> Void

    init(url: URL, title: String?, onClose: @escaping () -> Void) {
        model = MacReaderModel(url: url, title: title)
        self.onClose = onClose
        let hosting = NSHostingController(rootView: MacReaderView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 900))
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FastTabReaderWindow")
        super.init(window: window)
        window.delegate = self
        Task { await model.load() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.progressSink.stop()
        onClose()
    }
}
