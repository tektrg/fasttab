import SwiftUI
import FastTabSync

public struct SuggestBookmarksView: View {
    @ObservedObject var service = IntelligenceService.shared
    @ObservedObject var localCache = LocalCache.shared

    @State private var selectedURLForReader: URL?
    @State private var customPickSuggestion: FolderSuggestion?
    @State private var toastMessage: String?
    @State private var showToast: Bool = false

    public init() {}

    public var body: some View {
        Group {
            if service.isProcessing && service.folderSuggestions.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("Finding bookmark folders for your open tabs…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Matching semantic topics against your existing bookmark hierarchy.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.folderSuggestions.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue.opacity(0.8))
                    Text("All Tabs Organized")
                        .font(.title3.weight(.semibold))
                    Text("No pending bookmark suggestions for your open tabs right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Button {
                        service.analyze(force: true)
                    } label: {
                        Label("Recheck Suggestions", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(service.folderSuggestions) { suggestion in
                            FolderSuggestionCard(
                                suggestion: suggestion,
                                onSelectURL: { url in
                                    selectedURLForReader = url
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
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 80) // Spacing for floating sub-tab bar
                }
                .refreshable {
                    service.analyze(force: true)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: service.folderSuggestions.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: service.isProcessing)
        .sheet(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
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
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .shadow(radius: 8)
                    .padding(.bottom, 75)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func showToastHUD(message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showToast = false
            }
        }
    }
}

// MARK: - Folder Suggestion Card

struct FolderSuggestionCard: View {
    let suggestion: FolderSuggestion
    let onSelectURL: (URL) -> Void
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
        VStack(alignment: .leading, spacing: 12) {
            // Top Tab Info + Dismiss Button
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        if let url = URL(string: suggestion.tab.url) {
                            onSelectURL(url)
                        }
                    } label: {
                        Text(tabDisplayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        Text(suggestion.tab.browserName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(6)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            // Destination Folder & Reason Box
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.blue)

                    Text(suggestion.suggestedFolder.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(Int(suggestion.confidence * 100))% match")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }

                Text(suggestion.reason)
                    .font(.caption)
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
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Action Buttons
            HStack(spacing: 10) {
                Button(action: onAccept) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("Save to Folder")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onPickOther) {
                    Text("Other…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }
}
