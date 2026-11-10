import SwiftUI
import SafariServices
import WebKit
import FastTabSync

/// Simple `Identifiable` carrier for presenting `ReaderView` with `.readerPresentation(item:)`.
public struct ReaderNavigationItem: Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    public let title: String
    /// When set, the reader scrolls to and briefly flashes this highlight instead of
    /// restoring the last scroll position.
    public let focusHighlightID: String?

    public init(url: URL, title: String, focusHighlightID: String? = nil) {
        self.url = url
        self.title = title
        self.focusHighlightID = focusHighlightID
    }
}

/// Full-screen reader view. Shows a loading skeleton while Readability extracts the article,
/// renders it in `ReaderWebView`, and falls back to `SFSafariViewController` on failure.
public struct ReaderView: View {

    @StateObject private var viewModel: ReaderViewModel
    @StateObject private var readAloud = ReadAloudController()
    /// Read Again state for the End of Article button (marked here or synced in).
    @ObservedObject private var savedStore = SavedOnIPhoneStore.shared
    @Environment(\.dismiss) private var dismiss
    /// Set when presented with `.readerPresentation`: closing slides the reader out to the right.
    @Environment(\.readerSlide) private var slide
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    // Highlight bar state
    @State private var selectedText: String = ""
    @State private var selectedRange: String = ""
    @State private var showHighlightBar: Bool = false

    // Reading settings sheet / Read Aloud settings sheet
    @State private var showReadingSettings: Bool = false
    @State private var showReadAloudSettings: Bool = false

    // Highlight management sheet
    @State private var showHighlightsSheet: Bool = false

    // Tapped existing highlight: opens its comment thread (with Delete)
    @State private var tappedHighlightID: String? = nil

    // Extraction skeleton phase
    @State private var isLongExtraction: Bool = false

    // Header auto-hide on scroll
    @State private var isHeaderHidden: Bool = false

    // End of article options
    @State private var showBookmarkPicker: Bool = false
    @State private var toast: String? = nil
    @State private var isDismissing: Bool = false

    private func handleBack() {
        guard !isDismissing else { return }
        isDismissing = true
        if let slide { slide.dismiss() } else { dismiss() }
    }

    /// Left-edge swipe (page or chrome): the reader follows the finger when it slides;
    /// otherwise a far or fast enough swipe goes back.
    private func handleEdgeSwipe(_ swipe: ReaderEdgeSwipe) {
        guard !isDismissing else { return }
        if let slide {
            slide.handle(swipe)
            if slide.isLeaving { isDismissing = true }
        } else if case .ended(let translation, let velocity) = swipe, translation > 40 || velocity > 250 {
            handleBack()
        }
    }

    public init(url: URL, title: String, focusHighlightID: String? = nil) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(url: url, title: title, focusHighlightID: focusHighlightID))
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                readerBackground.ignoresSafeArea()

                switch viewModel.loadState {
                case .idle, .extracting:
                    extractingView

                case .loaded(let article):
                    readerContent(article: article)

                case .failed:
                    if let failure = viewModel.transcriptFailure {
                        TranscriptFailureView(
                            failure: failure, videoURL: viewModel.url,
                            retry: { Task { await viewModel.reloadArticle() } })
                    } else if viewModel.needsSafariReader {
                        safariReaderFallback
                    } else {
                        inAppWebView
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isLoaded || viewModel.needsSafariReader || isHeaderHidden ? .hidden : .automatic, for: .navigationBar)
            .animation(.easeInOut(duration: 0.25), value: isHeaderHidden)
            .toolbar {
                // Reader controls live in the floating bottom bar — nothing up top
                // once the article is loaded.
                if !isLoaded {
                    if viewModel.isFailed {
                        fallbackToolbarContent
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                handleBack()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Back")
                        }
                    }
                }
            }
            .overlay {
                ReadAloudTapFeedbackView(feedback: readAloud.tapFeedback)
            }
            // VoiceOver two-finger "Z" scrub = Back (slides out like the chevron).
            .accessibilityAction(.escape) { handleBack() }
            .overlay(alignment: .bottom) {
                VStack(spacing: DS.Space.sm) {
                    if showHighlightBar {
                        ReaderHighlightBar(
                            selectedText: selectedText,
                            onSelectColor: { color in
                                applyHighlight(color: color)
                            },
                            onDismiss: {
                                withAnimation { showHighlightBar = false }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                    }
                    ReadAloudNoticeView(notice: readAloud.engineNotice)
                    if readAloud.isAutoScrollPaused, readAloud.state != .idle {
                        ReadAloudBackToReadingButton { readAloud.isAutoScrollPaused = false }
                            .transition(.opacity)
                    }
                    if isLoaded {
                        bottomControlBar
                    }
                }
            }
        }
        .task {
            viewModel.loadInitialState()
            viewModel.readerDidOpen()
            await viewModel.extractIfNeeded()
            #if DEBUG
            // App Store screenshots: the `listenSettings` screen opens the Read Aloud settings sheet.
            if AppStoreDemo.isEnabled, AppStoreDemo.screen == .listenSettings {
                try? await Task.sleep(for: .seconds(1.5))
                showReadAloudSettings = true
            }
            #endif
        }
        .onDisappear {
            readAloud.stop()
            viewModel.flushPendingProgress()
            viewModel.readerDidClose()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                viewModel.flushPendingProgress()
            }
        }
        .onScreenEdgeSwipeBack { swipe in
            handleEdgeSwipe(swipe)
        }
        .sheet(isPresented: $showReadingSettings) {
            ReaderSettingsSheet()
        }
        .sheet(isPresented: $showReadAloudSettings) {
            ReadAloudSettingsSheet(voices: readAloudVoicesForCurrentArticle,
                                   articleLanguage: readAloudLanguageForCurrentArticle)
        }
        .sheet(isPresented: $showHighlightsSheet) {
            highlightsSheet
        }
        // Item, not a lookup in `viewModel.highlights`: deleting from the sheet removes it there
        // first, which would blank the sheet while it slides away.
        .sheet(item: Binding(
            get: { viewModel.highlights.first { $0.id == tappedHighlightID }.map(TappedHighlight.init) },
            set: { if $0 == nil { tappedHighlightID = nil } }
        )) { tapped in
            HighlightThreadSheet(highlight: tapped.highlight) {
                tappedHighlightID = nil
                viewModel.removeHighlight(id: tapped.highlight.id)
            }
        }
        .sheet(isPresented: $showBookmarkPicker) {
            BookmarkMovePicker(
                sourceDeviceID: activeDeviceID,
                title: "Save to Bookmark Folder"
            ) { destination in
                saveToBookmarkFolder(destination)
            }
        }
        .dsToast($toast, bottomInset: DS.Space.floatingBarClearance)
    }

    // MARK: - Loading Skeleton

    private var extractingView: some View {
        VStack(spacing: DS.Space.xl) {
            ProgressView()
            Text(isLongExtraction ? "Rendering article…" : "Extracting article…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isLongExtraction = true
        }
    }

    // MARK: - Reader Content

    /// Native backdrop behind the web view, following the effective background
    /// (custom light/dark pick + System/Light/Dark mode). Reads the view model's
    /// mirrored settings so the view refreshes live on every change.
    private var readerBackground: Color {
        Color(readerHex: viewModel.readerSettings.effectiveBackgroundHex(
            systemIsDark: colorScheme == .dark))
    }

    private func readerContent(article: ReaderArticle) -> some View {
        ReaderWebView(
            viewModel: viewModel,
            article: article,
            systemIsDark: colorScheme == .dark,
            onTextSelected: { text, range in
                withAnimation(.spring(response: 0.3)) {
                    selectedText = text
                    selectedRange = range
                    showHighlightBar = true
                }
            },
            onTextDeselected: {
                withAnimation { showHighlightBar = false }
            },
            onHighlightTapped: { id in
                tappedHighlightID = id
            },
            onEdgeSwipe: { swipe in
                handleEdgeSwipe(swipe)
            },
            onHeaderHiddenChanged: { hidden in
                isHeaderHidden = hidden
            },
            onDeleteLink: {
                deleteCurrentLink()
            },
            onSaveToBookmarkFolder: {
                showBookmarkPicker = true
            },
            isReadAgain: savedStore.isReadAgain(viewModel.url),
            onToggleReadAgain: {
                toggleReadAgain()
            },
            readAloud: ReadAloudPageState(
                position: readAloud.spokenPosition,
                chunks: readAloud.chunks,
                autoScroll: !readAloud.isAutoScrollPaused,
                tapToJumpEnabled: readAloud.hasBeenUsed
            ),
            onUserBeganScrolling: {
                if readAloud.state == .playing { readAloud.isAutoScrollPaused = true }
            },
            onReadAloudTap: { pageText, offset in
                readAloud.handleTap(pageText: pageText, offset: offset, article: article)
            },
            onReadAloudPageReady: { page in
                if readAloud.page !== page { readAloud.page = page }
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - In-App Fallback

    /// X Article whose body couldn't be fetched: Safari's own Reader, with its own close button.
    private var safariReaderFallback: some View {
        InAppBrowserView(url: viewModel.url, title: viewModel.title, entersReaderIfAvailable: true)
            .ignoresSafeArea()
    }

    private var inAppWebView: some View {
        ReaderInAppFallbackView(url: viewModel.url, viewModel: viewModel)
            .ignoresSafeArea(edges: .bottom)
    }

    @ToolbarContentBuilder
    private var fallbackToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                handleBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(viewModel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(viewModel.url.host() ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(item: viewModel.url) {
                Image(systemName: "square.and.arrow.up")
            }
            Button {
                UIApplication.shared.open(viewModel.url)
            } label: {
                Image(systemName: "safari")
            }
        }
    }

    // MARK: - Toolbar

    private var isLoaded: Bool {
        if case .loaded = viewModel.loadState { return true }
        return false
    }

    /// Floating bottom control bar. Replaces the old top `toolbarContent` —
    /// close, font size, highlights and the overflow menu all live here.
    /// While Read Aloud plays it shows only the transport (back 15 s / pause / forward 15 s);
    /// pausing or the end of playback brings the normal controls back.
    /// Every control is a 44pt tap target (HIG minimum).
    private var bottomControlBar: some View {
        let isReadingAloud = readAloud.state == .playing
        return ZStack {
            if isReadingAloud {
                ReadAloudTransportControls(controller: readAloud)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                standardBarControls
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .readerBottomBarGlass()
        .dsShadow(.floating)
        .padding(.horizontal, DS.Space.lg)
        // Clear the WebView's bottom progress bars (article + daily goal) + home indicator.
        .padding(.bottom, DS.Space.md)
        .offset(y: isHeaderHidden ? 120 : 0)
        .opacity(isHeaderHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: isHeaderHidden)
        .animation(.easeInOut(duration: 0.2), value: isReadingAloud)
    }

    /// The bar's normal controls: back, Read Aloud, video, transcript clean-up, highlights, •••.
    private var standardBarControls: some View {
        HStack(spacing: DS.Space.sm) {
            Button {
                handleBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .readerBarTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Divider()
                .frame(height: 24)

            if case .loaded(let article) = viewModel.loadState {
                ReadAloudButton(controller: readAloud, article: article)
            }

            if case .loaded(let article) = viewModel.loadState, article.youtubeVideoID != nil {
                Button {
                    viewModel.isVideoVisible.toggle()
                } label: {
                    Image(systemName: viewModel.isVideoVisible ? "play.rectangle.fill" : "play.rectangle")
                        .font(.body)
                        .readerBarTapTarget()
                }
                .accessibilityLabel(viewModel.isVideoVisible ? "Hide video" : "Show video")
            }

            if let cleanup = viewModel.transcriptCleanup, cleanup.isOffered {
                TranscriptCleanupToggle(cleanup: cleanup)
            }

            highlightsMenu
            moreActionsMenu
        }
    }

    /// Highlights list.
    private var highlightsMenu: some View {
        Menu {
            if viewModel.highlights.isEmpty {
                Text("No highlights yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.highlights) { h in
                    Button {
                        tappedHighlightID = h.id
                    } label: {
                        Label(
                            h.selectedText.prefix(40) + (h.selectedText.count > 40 ? "…" : ""),
                            systemImage: "circle.fill"
                        )
                        .foregroundStyle(h.color.swiftUIColor)
                    }
                }
                Divider()
                Button {
                    showHighlightsSheet = true
                } label: {
                    Label("Manage Highlights…", systemImage: "list.bullet")
                }
                Button(role: .destructive) {
                    viewModel.clearAllHighlights()
                } label: {
                    Label("Clear All Highlights", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "highlighter")
                .overlay(alignment: .topTrailing) {
                    if !viewModel.highlights.isEmpty {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
                }
                .readerBarTapTarget()
        }
    }

    /// More actions: reading / Read Aloud settings, reload, share, Safari, bookmark, delete.
    private var moreActionsMenu: some View {
        Menu {
            Button {
                showReadingSettings = true
            } label: {
                Label("Reading Settings", systemImage: "textformat.size")
            }
            Button {
                showReadAloudSettings = true
            } label: {
                Label("Read Aloud Settings", systemImage: "speaker.wave.2")
            }
            Divider()
            Button {
                isLongExtraction = false
                Task { await viewModel.reloadArticle() }
            } label: {
                Label("Reload Article", systemImage: "arrow.clockwise")
            }
            ShareLink(item: viewModel.url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            Button {
                UIApplication.shared.open(viewModel.url)
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
            Divider()
            Button {
                showBookmarkPicker = true
            } label: {
                Label("Save to Bookmark Folder…", systemImage: "folder.badge.plus")
            }
            Button(role: .destructive) {
                deleteCurrentLink()
            } label: {
                Label("Delete Link", systemImage: "trash")
            }
            if let cleanup = viewModel.transcriptCleanup, cleanup.isAvailable {
                Divider()
                Toggle(isOn: Binding(get: { cleanup.isEnabled }, set: { cleanup.setEnabled($0) })) {
                    Label("Clean Up Transcript (Experimental)", systemImage: "wand.and.sparkles")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .readerBarTapTarget()
        }
        .accessibilityLabel("More actions")
    }

    /// Voices for the loaded article's language, for the Read Aloud settings' voice picker.
    private var readAloudVoicesForCurrentArticle: [ReadAloudVoiceOption] {
        guard let language = readAloudLanguageForCurrentArticle else { return [] }
        return ReadAloudVoiceSelector.voices(for: language, among: readAloud.availableVoices)
    }

    private var readAloudLanguageForCurrentArticle: String? {
        guard case .loaded(let article) = viewModel.loadState else { return nil }
        return ReadAloudText.dominantLanguage(of: ReadAloudText.chunks(for: article))
    }

    // MARK: - Highlights Sheet

    private var highlightsSheet: some View {
        NavigationStack {
            Group {
                if viewModel.highlights.isEmpty {
                    DSEmptyState(
                        "No highlights yet",
                        systemImage: "highlighter",
                        message: "Long-press any text in the article to add a highlight."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.highlights) { h in
                            HStack(spacing: DS.Space.md) {
                                Circle()
                                    .fill(h.color.swiftUIColor)
                                    .frame(width: 14, height: 14)
                                Text(h.selectedText)
                                    .font(.subheadline)
                                    .lineLimit(3)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.removeHighlight(id: h.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .dsListRow()
                    }
                    .dsListStyle()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsCanvas()
            .navigationTitle("Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHighlightsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Highlight Action

    private func applyHighlight(color: HighlightColor) {
        withAnimation { showHighlightBar = false }
        guard !selectedRange.isEmpty else { return }
        viewModel.commitHighlight(selectedText: selectedText, serializedRange: selectedRange, color: color)
    }

    // MARK: - End of Article Actions

    private var activeDeviceID: String {
        if let tab = LocalCache.shared.findTab(url: viewModel.url) {
            return tab.deviceID
        }
        if let bm = LocalCache.shared.findBookmark(url: viewModel.url) {
            return bm.deviceID
        }
        if let macID = LocalCache.shared.state.connectedMac?.id, !macID.isEmpty {
            return macID
        }
        if let blobDevID = LocalCache.shared.state.bookmarkBlobs.first(where: { !$0.deviceID.isEmpty })?.deviceID {
            return blobDevID
        }
        return LocalCache.shared.state.devices.first?.id ?? ""
    }

    private func saveToBookmarkFolder(_ destination: BookmarkMoveDestination) {
        let targetDeviceID = activeDeviceID
        SyncConsumer.shared.sendAddBookmark(
            title: viewModel.title.isEmpty ? (viewModel.url.host() ?? viewModel.url.absoluteString) : viewModel.title,
            url: viewModel.url.absoluteString,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: targetDeviceID
        )
        toast = "Saved to \(destination.folderDisplayName)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// End of Article "Read Again" / "Remove from Read Again".
    private func toggleReadAgain() {
        toast = LinkReadState(saved: savedStore).toggleReadAgain(url: viewModel.url, title: viewModel.title)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func deleteCurrentLink() {
        let url = viewModel.url
        let normURL = normalizeURL(url)
        let canonical = url.readerCanonicalKey

        // 1. If it's in bookmark, delete it from bookmark.
        let matchingBookmarks = LocalCache.shared.findAllBookmarks(url: url)
        for match in matchingBookmarks {
            SyncConsumer.shared.sendDeleteBookmark(
                bookmark: match.bookmark,
                browserName: match.browserName,
                profileName: match.profileName,
                targetDeviceID: match.deviceID
            )
            LocalCache.shared.removeBookmark(id: match.bookmark.id)
        }

        // 2. If it's in open tab, close it.
        let matchingTabs = LocalCache.shared.findAllTabs(url: url)
        for tab in matchingTabs {
            SyncConsumer.shared.sendCloseTab(tab)
            LocalCache.shared.removeTab(id: tab.id)
        }

        // 3. If it's in the iOS list, delete it too.
        if let savedItem = SavedOnIPhoneStore.shared.item(forURL: url.absoluteString) {
            SavedOnIPhoneStore.shared.remove(id: savedItem.id)
        } else {
            for item in SavedOnIPhoneStore.shared.items {
                if let u = URL(string: item.url), u.readerCanonicalKey == canonical || normalizeURL(u) == normURL {
                    SavedOnIPhoneStore.shared.remove(id: item.id)
                    break
                }
            }
        }

        // Also clean up LastOpenedStore
        LastOpenedStore.shared.remove(url: url)

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        handleBack()
    }

    private func normalizeURL(_ u: URL) -> String {
        let host = (u.host() ?? "").lowercased()
        let path = u.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = (u.query() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(host)/\(path)".lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return "\(host)/\(path)?\(query)".lowercased()
        }
    }
}

// MARK: - Bottom Bar Glass

/// 44pt minimum tap target for the floating bottom-bar controls (HIG).
/// Applied inside the label so badges overlaid on the glyph stay anchored.
extension View {
    func readerBarTapTarget() -> some View {
        self
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Liquid Glass pill on iOS 26+, regular-material capsule on earlier versions
/// (deployment target is iOS 17).
extension View {
    @ViewBuilder
    func readerBottomBarGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(.regularMaterial))
        }
    }
}

// MARK: - Left Edge Swipe To Go Back

extension View {
    func onScreenEdgeSwipeBack(action: @escaping (ReaderEdgeSwipe) -> Void) -> some View {
        self.modifier(ScreenEdgeSwipeBackModifier(onSwipe: action))
    }
}

private struct ScreenEdgeSwipeBackModifier: ViewModifier {
    let onSwipe: (ReaderEdgeSwipe) -> Void

    func body(content: Content) -> some View {
        content
            .background(ScreenEdgeSwipeBackRepresentable(onSwipe: onSwipe))
    }
}

private struct ScreenEdgeSwipeBackRepresentable: UIViewControllerRepresentable {
    let onSwipe: (ReaderEdgeSwipe) -> Void

    func makeUIViewController(context: Context) -> ScreenEdgeSwipeBackViewController {
        ScreenEdgeSwipeBackViewController(onSwipe: onSwipe)
    }

    func updateUIViewController(_ uiViewController: ScreenEdgeSwipeBackViewController, context: Context) {
        uiViewController.onSwipe = onSwipe
    }
}

private final class ScreenEdgeSwipeBackViewController: UIViewController, UIGestureRecognizerDelegate {
    var onSwipe: (ReaderEdgeSwipe) -> Void
    private weak var gesture: UIScreenEdgePanGestureRecognizer?

    init(onSwipe: @escaping (ReaderEdgeSwipe) -> Void) {
        self.onSwipe = onSwipe
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        setupGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setupGesture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let g = gesture, let targetView = g.view {
            targetView.removeGestureRecognizer(g)
            gesture = nil
        }
    }

    private func setupGesture() {
        guard gesture == nil else { return }
        let targetVC = parent ?? self
        guard let targetView = targetVC.view else { return }

        let edgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edgeGesture.edges = .left
        edgeGesture.delegate = self
        targetView.addGestureRecognizer(edgeGesture)
        self.gesture = edgeGesture
    }

    @objc private func handleEdgePan(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        if let swipe = ReaderEdgeSwipe(recognizer) { onSwipe(swipe) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - In-App Fallback Web View

private struct ReaderInAppFallbackView: UIViewRepresentable {
    let url: URL
    let viewModel: ReaderViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.scrollView.delegate = context.coordinator
        context.coordinator.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.scrollView.delegate = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        let viewModel: ReaderViewModel
        weak var webView: WKWebView?
        private var hasRestoredScroll = false
        private var activeObserver: NSObjectProtocol?

        init(viewModel: ReaderViewModel) {
            self.viewModel = viewModel
            super.init()
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.recoverIfBlank()
            }
        }

        func invalidate() {
            if let activeObserver {
                NotificationCenter.default.removeObserver(activeObserver)
                self.activeObserver = nil
            }
        }

        deinit {
            if let activeObserver {
                NotificationCenter.default.removeObserver(activeObserver)
            }
        }

        /// iOS kills the web content process on screen lock / long background;
        /// without this the fallback page stays blank.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            hasRestoredScroll = false
            webView.reload()
        }

        private func recoverIfBlank() {
            guard let webView else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerHTML.length : -1") { [weak webView] result, _ in
                let length = (result as? Int) ?? (result as? NSNumber)?.intValue ?? -1
                if length <= 0 {
                    webView?.reload()
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Only track user-initiated scrolling, not programmatic layout or initial zero offset
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
            guard hasRestoredScroll || viewModel.scrollProgress <= 0.01 else { return }
            let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            guard maxOffset > 0 else { return }
            let progress = min(max(scrollView.contentOffset.y / maxOffset, 0.0), 1.0)
            viewModel.updateScrollProgress(progress)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasRestoredScroll else { return }
            hasRestoredScroll = true
            guard viewModel.scrollProgress > 0.01 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let maxOffset = webView.scrollView.contentSize.height - webView.scrollView.bounds.height
                if maxOffset > 0 {
                    let targetY = maxOffset * self.viewModel.scrollProgress
                    webView.scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
                }
            }
        }
    }
}

/// A tapped highlight as a sheet item, so the sheet keeps its own copy.
private struct TappedHighlight: Identifiable {
    let highlight: ReaderHighlight
    var id: String { highlight.id }
}


