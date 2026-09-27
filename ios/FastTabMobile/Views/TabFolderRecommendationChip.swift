import SwiftUI
import FastTabSync

/// Organize-mode row accessory: compact folder chip + "Bookmark" button.
/// Tapping Bookmark asks "Also close this tab?" unless the user chose
/// "Don't ask again", in which case the remembered answer runs in one tap.
struct TabFolderRecommendationChip: View {
    let recommendation: TabFolderRecommendation
    /// `closeTab` is true when the tab should also be closed on the Mac.
    let onBookmark: (_ closeTab: Bool) -> Void

    @AppStorage(TabBookmarkClosePreference.defaultsKey)
    private var closePreferenceRaw = TabBookmarkClosePreference.ask.rawValue
    @State private var isClosePromptShown = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Label(recommendation.folderName, systemImage: "folder")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xxs)
                .background(DS.Tint.action.opacity(0.12), in: Capsule())
                .foregroundStyle(DS.Tint.action)
                .accessibilityLabel("Suggested folder \(recommendation.folderName)")

            Button("Bookmark", action: handleBookmarkTap)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .sheet(isPresented: $isClosePromptShown) {
            AlsoCloseTabPrompt { closeTab, remember in
                if remember {
                    closePreferenceRaw = (closeTab ? TabBookmarkClosePreference.bookmarkAndClose : .bookmarkOnly).rawValue
                }
                isClosePromptShown = false
                onBookmark(closeTab)
            }
            .presentationDetents([.height(220)])
        }
    }

    private func handleBookmarkTap() {
        switch TabBookmarkClosePreference(rawValue: closePreferenceRaw) ?? .ask {
        case .ask: isClosePromptShown = true
        case .bookmarkAndClose: onBookmark(true)
        case .bookmarkOnly: onBookmark(false)
        }
    }
}

/// "Also close this tab?" Yes / No with a "Don't ask again" toggle.
private struct AlsoCloseTabPrompt: View {
    let onAnswer: (_ closeTab: Bool, _ remember: Bool) -> Void
    @State private var dontAskAgain = false

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            Text("Also close this tab?")
                .font(.headline)
            Toggle("Don't ask again", isOn: $dontAskAgain)
            HStack(spacing: DS.Space.md) {
                Button("No") { onAnswer(false, dontAskAgain) }
                    .buttonStyle(.dsTinted(DS.Tint.action))
                Button("Yes") { onAnswer(true, dontAskAgain) }
                    .buttonStyle(.dsPrimary)
            }
        }
        .padding(DS.Space.xl)
    }
}
