import SwiftUI
import SafariServices
import WebKit

/// Simple `Identifiable` carrier for presenting `ReaderView` via `fullScreenCover` or `sheet`.
public struct ReaderNavigationItem: Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    public let title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
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

    public init(url: URL, title: String) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(url: url, title: title))
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

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
            .toolbar(viewModel.needsSafariReader ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if case .loaded = viewModel.loadState {
                    toolbarContent
                } else if viewModel.isFailed {
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
            .overlay(alignment: .bottom) {
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
        VStack(spacing: 24) {
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Font size
            Button {
                showFontSizeControls.toggle()
            } label: {
                Image(systemName: "textformat.size")
            }
            .popover(isPresented: $showFontSizeControls) {
                fontSizePopover
            }

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
        }
    }

    // MARK: - Font Size Popover

    private var fontSizePopover: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.decreaseFontSize()
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Circle())
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
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.fontSize >= 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Highlights Sheet

    private var highlightsSheet: some View {
        NavigationStack {
            Group {
                if viewModel.highlights.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "highlighter")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("No highlights yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Long-press any text in the article to add a highlight.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.highlights) { h in
                            HStack(spacing: 12) {
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
                    }
                }
            }
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
