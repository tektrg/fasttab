import SwiftUI
import SafariServices
import WebKit

/// Simple `Identifiable` carrier for presenting `ReaderView` via `fullScreenCover` or `sheet`.
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Highlight bar state
    @State private var selectedText: String = ""
    @State private var selectedRange: String = ""
    @State private var showHighlightBar: Bool = false

    // Font size sheet
    @State private var showFontSizeControls: Bool = false

    // Highlight management sheet
    @State private var showHighlightsSheet: Bool = false

    // Tapped existing highlight (for delete option)
    @State private var tappedHighlightID: String? = nil

    // Extraction skeleton phase
    @State private var isLongExtraction: Bool = false

    // Header auto-hide on scroll
    @State private var isHeaderHidden: Bool = false

    public init(url: URL, title: String, focusHighlightID: String? = nil) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(url: url, title: title, focusHighlightID: focusHighlightID))
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Palette.readerPage.ignoresSafeArea()

                switch viewModel.loadState {
                case .idle, .extracting:
                    extractingView

                case .loaded(let article):
                    readerContent(article: article)

                case .failed:
                    if viewModel.needsSafariReader {
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
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
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
                    if isLoaded {
                        bottomControlBar
                    }
                }
            }
        }
        .task {
            viewModel.loadInitialState()
            await viewModel.extractIfNeeded()
        }
        .onDisappear {
            viewModel.flushPendingProgress()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                viewModel.flushPendingProgress()
            }
        }
        .sheet(isPresented: $showHighlightsSheet) {
            highlightsSheet
        }
        .confirmationDialog("Remove Highlight?", isPresented: Binding(
            get: { tappedHighlightID != nil },
            set: { if !$0 { tappedHighlightID = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let id = tappedHighlightID {
                    viewModel.removeHighlight(id: id)
                    tappedHighlightID = nil
                }
            }
        }
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

    private func readerContent(article: ReaderArticle) -> some View {
        ReaderWebView(
            viewModel: viewModel,
            article: article,
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
            onHeaderHiddenChanged: { hidden in
                isHeaderHidden = hidden
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
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
    private var bottomControlBar: some View {
        HStack(spacing: DS.Space.lg) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close reader")

            Divider()
                .frame(height: 24)

            // Font size
            Button {
                showFontSizeControls.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.body)
            }
            .popover(isPresented: $showFontSizeControls) {
                fontSizePopover
            }
            .accessibilityLabel("Font size")

            // Highlights list
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
            }

            // Share / open in Safari / reload
            Menu {
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .readerBottomBarGlass()
        .dsShadow(.floating)
        .padding(.horizontal, DS.Space.lg)
        // Clear the WebView's bottom progress bar + home indicator.
        .padding(.bottom, DS.Space.sm)
        .offset(y: isHeaderHidden ? 120 : 0)
        .opacity(isHeaderHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: isHeaderHidden)
    }

    // MARK: - Font Size Popover

    private var fontSizePopover: some View {
        HStack(spacing: DS.Space.lg) {
            Button {
                viewModel.decreaseFontSize()
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: DS.IconSize.row, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(DS.Palette.surfaceMuted, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.fontSize <= 14)

            Text("\(viewModel.fontSize) pt")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 52)

            Button {
                viewModel.increaseFontSize()
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: DS.IconSize.row, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(DS.Palette.surfaceMuted, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.fontSize >= 28)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .presentationCompactAdaptation(.popover)
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

    private func applyHighlight(color: HighlightColor) {        withAnimation { showHighlightBar = false }
        guard !selectedRange.isEmpty else { return }
        viewModel.commitHighlight(selectedText: selectedText, serializedRange: selectedRange, color: color)
    }
}

// MARK: - Bottom Bar Glass

/// Liquid Glass pill on iOS 26+, regular-material capsule on earlier versions
/// (deployment target is iOS 17).
private extension View {
    @ViewBuilder
    func readerBottomBarGlass() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(.regularMaterial))
        }
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

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        let viewModel: ReaderViewModel
        weak var webView: WKWebView?
        private var hasRestoredScroll = false

        init(viewModel: ReaderViewModel) {
            self.viewModel = viewModel
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
