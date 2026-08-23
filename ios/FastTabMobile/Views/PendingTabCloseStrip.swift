import SwiftUI
import FastTabSync

/// One tab the user asked to close, tied to the command carrying the request.
///
/// Deliberately stores no outcome. The outcome is read back from `LocalCache` by
/// `commandID` every time it is rendered, so this is an *association* between a
/// row and a command — not a second copy of the truth that could drift out of
/// step with what actually happened.
struct PendingTabClose: Identifiable, Equatable {
    let tabID: String
    let commandID: String
    let tabTitle: String

    var id: String { tabID }
}

/// A close request paired with its current, freshly-read outcome.
struct TrackedTabClose: Identifiable, Equatable {
    let close: PendingTabClose
    let progress: CommandProgress

    var id: String { close.tabID }
}

/// Reports close requests that have not finished, and — the part that used to be
/// missing entirely — the ones that failed, so the user finds out that the tab
/// they "closed" is still open on their Mac.
struct PendingTabCloseStrip: View {
    let tracked: [TrackedTabClose]
    let onDismissFailure: (PendingTabClose) -> Void

    private var failures: [TrackedTabClose] {
        tracked.filter { $0.progress.isFailure }
    }

    private var unfinished: [TrackedTabClose] {
        tracked.filter { !$0.progress.isSettled }
    }

    var body: some View {
        if !failures.isEmpty || !unfinished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures) { item in
                    failureRow(item)
                }

                if let summary = unfinishedSummary {
                    unfinishedRow(summary)
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
    private func failureRow(_ item: TrackedTabClose) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.progress.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(item.progress.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Still open: \(item.close.tabTitle)")
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
                onDismissFailure(item.close)
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

    // MARK: - Still in flight

    /// One line for however many closes are in flight. The wording names the
    /// *slowest* stage, because that is the one the user might be able to fix:
    /// a request still sitting on the phone is a phone problem, whereas one
    /// already uploaded is just a Mac that has not woken up yet.
    private var unfinishedSummary: String? {
        guard let slowest = unfinished.map(\.progress).min(by: { rank(of: $0.stage) < rank(of: $1.stage) }) else {
            return nil
        }
        let subject = unfinished.count == 1 ? "1 tab" : "\(unfinished.count) tabs"
        return "Closing \(subject) — \(slowest.label.lowercasedFirstWord)"
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
