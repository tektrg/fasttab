import SwiftUI
import FastTabSync

public struct SuggestBookmarksView: View {
    @ObservedObject var service = IntelligenceService.shared
    @ObservedObject var localCache = LocalCache.shared

    @State private var selectedBrowserURL: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var customPickSuggestion: FolderSuggestion?
    @State private var toast: String?

    public init() {}

    public var body: some View {
        Group {
            if service.isProcessing && service.folderSuggestions.isEmpty {
                VStack(spacing: DS.Space.lg) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Finding bookmark folders for your open tabs…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Matching semantic topics against your existing bookmark hierarchy.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.xxl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.folderSuggestions.isEmpty {
                DSEmptyState(
                    "All Tabs Organized",
                    systemImage: "folder.badge.gearshape",
                    message: "No pending bookmark suggestions for your open tabs right now.",
                    tint: DS.Tint.action,
                    style: .fullScreen
                ) {
                    Button {
                        service.analyze(force: true)
                    } label: {
                        Label("Recheck Suggestions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.dsPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.lg) {
                        ForEach(service.folderSuggestions) { suggestion in
                            FolderSuggestionCard(
                                suggestion: suggestion,
                                onSelectURL: { url in
                                    selectedBrowserURL = url
                                },
                                onOpenInReader: { url, title in
                                    readerItem = ReaderNavigationItem(url: url, title: title)
                                },
                                onAccept: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        service.acceptSuggestion(suggestion)
                                    }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    showToastHUD(message: "Saved to \(suggestion.suggestedFolder.displayName)")
                                },
                                onPickOther: {
                                    customPickSuggestion = suggestion
                                },
                                onDismiss: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        service.dismissSuggestion(id: suggestion.id)
                                    }
                                }
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.md)
                    .padding(.bottom, DS.Space.floatingBarClearance) // Spacing for floating sub-tab bar
                }
                .refreshable {
                    service.analyze(force: true)
                }
            }
        }
        .dsCanvas()
        .animation(.easeInOut(duration: 0.25), value: service.folderSuggestions.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: service.isProcessing)
        .sheet(item: $selectedBrowserURL) { url in
            InAppBrowserView(url: url)
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
        .sheet(item: $customPickSuggestion) { suggestion in
            BookmarkMovePicker(
                sourceDeviceID: suggestion.tab.deviceID,
                title: "Save Tab to…"
            ) { destination in
                SyncConsumer.shared.sendAddBookmark(
                    title: suggestion.tab.title.isEmpty ? suggestion.tab.url : suggestion.tab.title,
                    url: suggestion.tab.url,
                    destinationBrowserName: destination.browserName,
                    destinationProfileName: destination.profileName,
                    destinationFolderPath: destination.folderPath,
                    targetDeviceID: suggestion.tab.deviceID
                )
                withAnimation {
                    service.dismissSuggestion(id: suggestion.id)
                }
                showToastHUD(message: "Saved to \(destination.folderDisplayName)")
                customPickSuggestion = nil
            }
        }
        .dsToast($toast, bottomInset: DS.Space.floatingBarClearance)
    }

    private func showToastHUD(message: String) {
        toast = message
    }
}

// MARK: - Folder Suggestion Card

struct FolderSuggestionCard: View {
    let suggestion: FolderSuggestion
    let onSelectURL: (URL) -> Void
    let onOpenInReader: (URL, String) -> Void
    let onAccept: () -> Void
    let onPickOther: () -> Void
    let onDismiss: () -> Void

    private var tabDisplayTitle: String {
        if !suggestion.tab.title.isEmpty { return suggestion.tab.title }
        return URL(string: suggestion.tab.url)?.host() ?? suggestion.tab.url
    }

    private var host: String {
        URL(string: suggestion.tab.url)?.host() ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // Top Tab Info + Dismiss Button
            HStack(alignment: .top) {
                Button {
                    if let url = URL(string: suggestion.tab.url) {
                        onSelectURL(url)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(tabDisplayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            Text(suggestion.tab.browserName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(DS.Tint.action)

                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text(host)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let url = URL(string: suggestion.tab.url) {
                        Button {
                            onOpenInReader(url, tabDisplayTitle)
                        } label: {
                            Label("Open in Reader", systemImage: "doc.plaintext")
                        }

                        Link(destination: url) {
                            Label("Open in Safari", systemImage: "safari")
                        }

                        ShareLink(item: url) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            UIPasteboard.general.string = suggestion.tab.url
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }

                        Button {
                            SyncConsumer.shared.sendOpenOnMac(url: suggestion.tab.url, title: tabDisplayTitle)
                        } label: {
                            Label("Open on Mac", systemImage: "laptopcomputer")
                        }
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .padding(6)
                        .background(Circle().fill(DS.Palette.surfaceMuted))
                }
                .buttonStyle(.plain)
            }

            // Destination Folder & Reason Box
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.footnote)
                        .foregroundStyle(DS.Tint.action)

                    Text(suggestion.suggestedFolder.displayName)
                        .font(DS.Font.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    DSTag("\(Int(suggestion.confidence * 100))% match", tint: DS.Tint.action)
                }

                Text(suggestion.reason)
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !suggestion.suggestedFolder.sampleBookmarkTitles.isEmpty {
                    Text("In this folder: \(suggestion.suggestedFolder.sampleBookmarkTitles.prefix(2).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

            // Action Buttons
            HStack(spacing: DS.Space.sm) {
                Button(action: onAccept) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                        Text("Save to Folder")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPrimary)

                // Same height as the primary capsule beside it, so no `.dsTinted` (its
                // shorter padding would leave the pair uneven).
                Button(action: onPickOther) {
                    Text("Other…")
                        .font(DS.Font.cardTitle)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.md)
                        .background(DS.Palette.surfaceMuted, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .dsCard()
    }
}
