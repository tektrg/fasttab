import SwiftUI

/// Find in Article bar: replaces the reader's bottom control bar while Find is open and rides
/// above the keyboard. Return = next match; Done clears every find highlight.
struct ReaderFindBar: View {
    @ObservedObject var find: ReaderFindController
    @Binding var query: String
    let onDone: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Article", text: $query)
                    .focused($isFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        find.next()
                        isFocused = true // keep the keyboard up for repeated Return
                    }
                    .accessibilityIdentifier("reader.find.field")
                Text(find.state.countLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("reader.find.count")
            }
            .padding(.leading, DS.Space.sm)

            Button { find.previous() } label: {
                Image(systemName: "chevron.up").readerBarTapTarget()
            }
            .accessibilityLabel("Previous match")
            .disabled(find.state.matchCount == 0)

            Button { find.next() } label: {
                Image(systemName: "chevron.down").readerBarTapTarget()
            }
            .accessibilityLabel("Next match")
            .disabled(find.state.matchCount == 0)

            Button("Done", action: onDone)
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
                .accessibilityIdentifier("reader.find.done")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.xs)
        .readerBottomBarGlass()
        .dsShadow(.floating)
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
        .onChange(of: query) { _, newValue in find.setQuery(newValue) }
        .onAppear { isFocused = true }
        .task(id: find.state.voiceOverAnnouncement) {
            // Restarts on every change, so only the settled count is spoken.
            guard let text = find.state.voiceOverAnnouncement else { return }
            try? await Task.sleep(for: ReaderFindState.announcementDelay)
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}
