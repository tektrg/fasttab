import SwiftUI
import FastTabSync

/// Which kind of in-flight bookmark request a row is tracking. Delete and
/// move share this one strip/tracking mechanism rather than duplicating it a
/// third time — see the comment on `PendingBookmarkAction` for why.
enum BookmarkActionKind: Equatable {
    case delete
    case move
}

/// One bookmark action the user asked for, tied to the command carrying the
/// request. Deliberately stores no outcome, for the same reason as
/// `PendingTabClose`: the outcome is read back from `LocalCache` by `commandID`
/// every time it is rendered, so this is an *association* between a row and a
/// command, not a second copy of the truth that could drift out of step.
///
/// Originally this was `PendingBookmarkDelete`, a near-duplicate of
/// `PendingTabClose`. Move is a second bookmark action needing the exact same
/// hide-until-resolved tracking, so this generalizes over `kind` instead of
/// becoming a third near-identical type.
struct PendingBookmarkAction: Identifiable, Equatable {
    /// The owning blob's id (`deviceID|browserName|profileName`, see
    /// `BookmarkSource.blobID`/`SyncedBookmarkBlob.id`). `bookmarkID` alone is
    /// not globally unique — Chromium assigns small integer ids independently
    /// per profile, and Safari falls back to the raw URL — so every lookup key
    /// here pairs the two rather than trusting `bookmarkID` on its own.
    let blobID: String
    let bookmarkID: String
    let commandID: String
    let bookmarkTitle: String
    let kind: BookmarkActionKind

    var id: String { "\(kind)|\(blobID)#\(bookmarkID)" }

    /// The row-hiding key: delete and move both hide the same underlying
    /// bookmark row while in flight, regardless of which kind is pending.
    var hideKey: String { "\(blobID)#\(bookmarkID)" }
}

/// A request paired with its current, freshly-read outcome.
struct TrackedBookmarkAction: Identifiable, Equatable {
    let action: PendingBookmarkAction
    let progress: CommandProgress

    var id: String { action.id }
}

/// Reports bookmark actions that have not finished, and the ones that failed,
/// so the user finds out a "deleted"/"moved" bookmark is still where it was.
/// Mirrors `PendingTabCloseStrip` — see that file for the reasoning behind the
/// failures/unfinished split.
struct PendingBookmarkActionStrip: View {
    let tracked: [TrackedBookmarkAction]
    let onDismissFailure: (PendingBookmarkAction) -> Void

    private var failures: [TrackedBookmarkAction] {
        tracked.filter { $0.progress.isFailure }
    }

    private var unfinished: [TrackedBookmarkAction] {
        tracked.filter { !$0.progress.isSettled }
    }

    var body: some View {
        if !failures.isEmpty || !unfinished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures) { item in
                    failureRow(item)
                }

                ForEach(unfinishedSummaries, id: \.kind) { summary in
                    unfinishedRow(summary.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Failures

    @ViewBuilder
    private func failureRow(_ item: TrackedBookmarkAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.progress.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(item.progress.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(failureHeaderVerb(for: item.action.kind)): \(item.action.bookmarkTitle)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(item.progress.detail ?? item.progress.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                onDismissFailure(item.action)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    // 40x40 minimum touch target, kept clear of the row's own
                    // tap area by the trailing padding.
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.progress.tint.opacity(0.12))
        )
    }

    /// A failed delete always leaves the bookmark exactly where it was — "Still
    /// there" is always accurate. A failed move does not: the Mac tries to put
    /// it back, but that restore can itself fail (see `handleMoveBookmarkCommand`
    /// in `SyncService+CommandDelivery.swift`), in which case the bookmark may
    /// really be gone. "Couldn't move" stays true either way, so move never
    /// claims a location the code can't actually guarantee.
    private func failureHeaderVerb(for kind: BookmarkActionKind) -> String {
        kind == .delete ? "Still there" : "Couldn't move"
    }

    // MARK: - Still in flight

    private struct UnfinishedSummary {
        let kind: BookmarkActionKind
        let text: String
    }

    /// One line per kind (delete/move) that has in-flight items, each naming
    /// the *slowest* stage among that kind's items — same rationale as
    /// `PendingTabCloseStrip`. Kept separate per kind so "Deleting 2" and
    /// "Moving 1" never collapse into a misleading single count.
    private var unfinishedSummaries: [UnfinishedSummary] {
        [BookmarkActionKind.delete, .move].compactMap { kind in
            let items = unfinished.filter { $0.action.kind == kind }
            guard let slowest = items.map(\.progress).min(by: { rank(of: $0.stage) < rank(of: $1.stage) }) else {
                return nil
            }
            let verb = kind == .delete ? "Deleting" : "Moving"
            let subject = items.count == 1 ? "1 bookmark" : "\(items.count) bookmarks"
            return UnfinishedSummary(kind: kind, text: "\(verb) \(subject) — \(slowest.label.lowercasedFirstWord)")
        }
    }

    private func rank(of stage: CommandProgress.Stage) -> Int {
        switch stage {
        case .waitingToUpload: return 0
        case .waitingForApproval: return 1
        case .waitingForMac: return 2
        case .runningOnMac: return 3
        case .succeeded, .failed: return 4
        }
    }

    @ViewBuilder
    private func unfinishedRow(_ summary: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)

            Text(summary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}

private extension String {
    /// "Sent — waiting for your Mac" reads wrong mid-sentence with a capital S.
    /// Only the first character is touched, so "Mac" and "iPhone" keep their case.
    var lowercasedFirstWord: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
