import SwiftUI
import FastTabSync

/// What has actually happened to one outbound command, in the user's terms.
///
/// Combines the two facts the UI must never conflate:
///
/// - `SyncCommandDelivery` — has this phone managed to upload the request at
///   all? If not, the phone's network is the problem and the user can act.
/// - `SyncCommand.status` — what did the receiving Mac decide? A Mac that is
///   asleep leaves this at `.pending` for as long as it likes, and there is
///   nothing for the user to do about that.
///
/// Pure and UI-state-free so the wording can be reasoned about without a live
/// iCloud account.
struct CommandProgress: Equatable {

    /// Where the request has got to. Deliberately six cases rather than a
    /// success/failure boolean: "stuck on this phone" and "waiting on a sleeping
    /// Mac" look identical in a spinner and mean completely different things.
    enum Stage: Equatable {
        /// Written down durably on this phone; iCloud has not accepted it yet.
        case waitingToUpload
        /// iCloud has it. The target Mac has not acted yet.
        case waitingForMac
        /// The Mac is carrying it out right now.
        case runningOnMac
        /// The Mac has seen it and is asking its own user to confirm.
        case waitingForApproval
        /// It happened.
        case succeeded
        /// Terminal, and it did not happen.
        case failed
    }

    let stage: Stage
    let symbolName: String
    let label: String
    let tint: Color
    /// The Mac's own explanation, when it sent one.
    let detail: String?

    var isFailure: Bool { stage == .failed }
    var isSettled: Bool { stage == .succeeded || stage == .failed }

    static func of(command: SyncCommand, delivery: SyncCommandDelivery) -> CommandProgress {
        // The Mac's verdict outranks delivery: once it has written a terminal
        // status back, the upload question is settled by definition.
        switch command.status {
        case .done:
            return CommandProgress(
                stage: .succeeded,
                symbolName: "checkmark.circle.fill",
                label: successLabel(for: command.kind),
                tint: .green,
                detail: nil
            )

        case .notFound:
            return CommandProgress(
                stage: .failed,
                symbolName: "questionmark.circle.fill",
                label: notFoundLabel(for: command.kind),
                tint: .orange,
                detail: command.statusReason
            )

        case .refused:
            return CommandProgress(
                stage: .failed,
                symbolName: "xmark.circle.fill",
                label: "Your Mac declined this",
                tint: .red,
                detail: command.statusReason
            )

        case .expired:
            return CommandProgress(
                stage: .failed,
                symbolName: "clock.badge.xmark",
                label: "Expired before your Mac saw it",
                tint: .secondary,
                detail: command.statusReason
            )

        case .needsApproval:
            return CommandProgress(
                stage: .waitingForApproval,
                symbolName: "hand.raised.fill",
                label: "Waiting for approval on your Mac",
                tint: .orange,
                detail: command.statusReason
            )

        case .inProgress:
            return CommandProgress(
                stage: .runningOnMac,
                symbolName: "arrow.triangle.2.circlepath",
                label: "Your Mac is doing it now",
                tint: .indigo,
                detail: nil
            )

        case .pending:
            switch delivery {
            case .queuedLocally:
                return CommandProgress(
                    stage: .waitingToUpload,
                    symbolName: "arrow.up.circle",
                    label: "Waiting to upload from this iPhone",
                    tint: .orange,
                    detail: nil
                )
            case .uploaded, .acknowledged:
                return CommandProgress(
                    stage: .waitingForMac,
                    symbolName: "clock",
                    label: "Sent — waiting for your Mac",
                    tint: .blue,
                    detail: nil
                )
            }
        }
    }

    // MARK: - Per-kind wording

    private static func successLabel(for kind: SyncCommandKind) -> String {
        switch kind {
        case .openOnMac: return "Opened on your Mac"
        case .closeTab: return "Closed on your Mac"
        case .deleteBookmark: return "Bookmark deleted on your Mac"
        case .deleteHistoryItem: return "History entry deleted on your Mac"
        case .moveBookmark: return "Bookmark moved on your Mac"
        case .addBookmark: return "Bookmark saved on your Mac"
        case .createFolder: return "Folder created on your Mac"
        }
    }

    private static func notFoundLabel(for kind: SyncCommandKind) -> String {
        switch kind {
        case .openOnMac: return "Your Mac couldn't open this link"
        case .closeTab: return "Your Mac couldn't find that tab"
        case .deleteBookmark: return "Your Mac couldn't find that bookmark"
        case .deleteHistoryItem: return "Your Mac couldn't find that history entry"
        case .moveBookmark: return "Your Mac couldn't find that bookmark"
        case .addBookmark: return "Your Mac couldn't save that bookmark"
        case .createFolder: return "Your Mac couldn't create that folder"
        }
    }
}
