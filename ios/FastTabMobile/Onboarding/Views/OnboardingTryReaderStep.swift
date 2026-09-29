import SwiftUI
import FastTabSync

/// Screen 3: open one real article in the real reader.
///
/// Prefers one of the user's own synced tabs (`ReaderTryoutPicker`); without a
/// suitable tab, or after "Continue without a Mac", it opens the bundled
/// `ReaderSampleArticle`, which works offline.
struct OnboardingTryReaderStep: View {
    let useSampleOnly: Bool
    let isStandalone: Bool
    let onContinue: () -> Void

    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var preloader = ReaderPreloader.shared
    /// Delayed copy of "still preparing", so a preload that finishes in a blink never flashes text.
    @State private var showsPreparing = false
    @State private var readerItem: ReaderNavigationItem?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The article to demo, fixed on first appearance so the card doesn't swap
    /// under the user's thumb when a sync lands mid-screen.
    @State private var pinnedTab: SyncedTab?
    @State private var hasPinnedChoice = false

    var body: some View {
        OnboardingStepLayout(
            systemImage: "doc.plaintext.fill",
            tint: DS.Tint.recent,
            title: "Read without the clutter",
            message: "Reader turns an article into clean, comfortable text."
        ) {
            VStack(spacing: DS.Space.md) {
                articleCard
                Label("Select any text to highlight it", systemImage: "highlighter")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            OnboardingPrimaryButton(title: isStandalone ? "Done" : "Continue", action: onContinue)
        }
        .onAppear {
            pinChoiceOnce()
            startPreload()
        }
        .onChange(of: preloader.status) { _, newStatus in
            if newStatus == .failed { fallBackToSampleIfPreloadFailed() }
        }
        .task(id: preloader.status) { await revealPreparingIfSlow() }
        .onDisappear { ReaderPreloader.shared.cancel() }
        .fullScreenCover(item: $readerItem, onDismiss: forgetSampleVisit) { item in
            ReaderView(url: item.url, title: item.title)
        }
    }

    private var articleCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSTag(
                pinnedTab == nil ? "Sample article" : "From your Mac",
                tint: pinnedTab == nil ? DS.Tint.recent : DS.Tint.action,
                systemImage: pinnedTab == nil ? "book" : "laptopcomputer"
            )
            Text(articleTitle)
                .font(DS.Font.cardTitle)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            Text(articleDomain)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsPreparing && preloader.status == .preparing {
                Label("Preparing…", systemImage: "hourglass")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button(action: openArticle) {
                Label("Open in Reader", systemImage: "doc.plaintext")
            }
            .buttonStyle(.dsTinted(DS.Tint.action))
            .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var articleTitle: String {
        pinnedTab?.title ?? ReaderSampleArticle.title
    }

    private var articleDomain: String {
        guard let pinnedTab else { return ReaderSampleArticle.siteName }
        return URL(string: pinnedTab.url)?.host() ?? pinnedTab.url
    }

    private func pinChoiceOnce() {
        guard !hasPinnedChoice else { return }
        hasPinnedChoice = true
        pinnedTab = useSampleOnly ? nil : ReaderTryoutPicker.pick(from: localCache.state.tabs)
    }

    /// Starts (or reuses) the background prep the flow began earlier; opening is then instant.
    private func startPreload() {
        if let pinnedTab, let url = URL(string: pinnedTab.url) {
            preloader.preload(url: url)
        } else {
            preloader.preloadSample()
        }
    }

    /// The Mac's article couldn't be fetched (offline, blocked): quietly demo the sample instead.
    private func fallBackToSampleIfPreloadFailed() {
        guard pinnedTab != nil, readerItem == nil else { return }
        withAnimation { pinnedTab = nil }
        preloader.preloadSample()
    }

    private func revealPreparingIfSlow() async {
        guard preloader.status == .preparing else {
            showsPreparing = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        withAnimation { showsPreparing = true }
    }

    /// The bundled sample is a demo, not something the user chose to read: keep
    /// it out of Last Opened and the "Continue reading" bar on the Read tab. A
    /// real tab from the user's Mac stays in history like any other read.
    private func forgetSampleVisit() {
        guard pinnedTab == nil else { return }
        LastOpenedStore.shared.remove(url: ReaderSampleArticle.url)
    }

    private func openArticle() {
        if let pinnedTab, let url = URL(string: pinnedTab.url) {
            readerItem = ReaderNavigationItem(url: url, title: pinnedTab.title)
            return
        }
        ReaderSampleArticle.seedReaderCache()
        readerItem = ReaderNavigationItem(url: ReaderSampleArticle.url, title: ReaderSampleArticle.title)
    }
}
