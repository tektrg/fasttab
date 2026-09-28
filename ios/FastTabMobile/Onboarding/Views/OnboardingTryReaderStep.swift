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
    @State private var readerItem: ReaderNavigationItem?

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
                Label("Long-press any text to highlight", systemImage: "highlighter")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            OnboardingPrimaryButton(title: isStandalone ? "Done" : "Continue", action: onContinue)
        }
        .onAppear(perform: pinChoiceOnce)
        .fullScreenCover(item: $readerItem) { item in
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
                .lineLimit(3)
            Text(articleDomain)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    private func openArticle() {
        if let pinnedTab, let url = URL(string: pinnedTab.url) {
            readerItem = ReaderNavigationItem(url: url, title: pinnedTab.title)
            return
        }
        ReaderSampleArticle.seedReaderCache()
        readerItem = ReaderNavigationItem(url: ReaderSampleArticle.url, title: ReaderSampleArticle.title)
    }
}
