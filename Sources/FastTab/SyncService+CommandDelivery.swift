import Foundation
import CloudKit
import FastTabSync

/// Execution of commands sent to this Mac from another device.
///
/// Split out of `SyncService` so that file stays about local state and
/// transport, while this one holds the policy for acting on a remote request —
/// addressing, expiry, idempotence, and the per-kind handlers.
extension SyncService {
    func handleIncomingCommand(_ command: SyncCommand) {
        guard Self.shouldProcessIncomingCommand(command) else { return }

        guard IncomingCommandFilter.isAddressedToDevice(command, deviceID: deviceID) else {
            return
        }

        // Expiry as garbage collection: with a 7-day TTL, a command this old was
        // never going to be acted on, so answer it once and let the phone retire
        // the record. This gate must stay ahead of the duplicate check below —
        // it is what lets the journal's settled ledger forget expired commands
        // without reopening the double-execution hole.
        if Self.hasExpired(command) {
            var expiredCmd = command
            expiredCmd.status = .expired
            expiredCmd.statusReason = "Command expired before processing"
            expiredCmd.completedAt = Date()
            pushCommandResult(expiredCmd)
            return
        }

        // Already-answered commands are re-pushed rather than re-executed, for
        // every command kind. Two separate redeliveries land here:
        //
        // 1. The answering write is still in flight (recovery sweep, or a
        //    re-fetch of the same record) — the journal's outbox catches it.
        // 2. The phone's outbox is at-least-once, so a phone killed before it
        //    saw its own save confirmation re-uploads the command re-derived
        //    from stored values, i.e. back at `.pending`, clobbering our
        //    terminal status on the server. The journal's settled ledger — which
        //    outlives the response acknowledgement — catches that one.
        //
        // Re-pushing rather than dropping is what closes the loop: it re-asserts
        // the terminal status the phone's `.pending` overwrote, so the phone
        // finally learns the outcome and can clear its own outbox. Dropping
        // silently would leave a finished command looking unfinished forever.
        // Without either guard, a second `closeTab` closes an innocent tab and a
        // second `deleteBookmark` re-raises an approval the user dismissed.
        let duplicateDecision = commandJournal.decision(for: command)
        if case .resendCompleted(let response) = duplicateDecision {
            pushCommandResult(response)
            return
        }

        switch command.kind {
        case .openOnMac:
            SentLinkInbox.shared.receive(command: command)
        case .closeTab:
            // A close interrupted mid-flight is re-entered rather than re-run
            // blind; the handler treats an already-absent tab as done. The
            // resend case returned above, so anything left that isn't `.execute`
            // is an interrupted execution.
            handleCloseTabCommand(
                command,
                reconcilingExecution: duplicateDecision != .execute
            )
        case .deleteBookmark, .deleteHistoryItem:
            handleDeleteCommand(command)
        case .moveBookmark:
            // Runs immediately, unlike delete — there is no Mac-side approval
            // step for this command kind. The remove-then-insert-with-rollback
            // in `handleMoveBookmarkCommand` is the safety net standing in for
            // the approval step this kind deliberately skips.
            handleMoveBookmarkCommand(command)
        case .addBookmark:
            // Adds a brand-new bookmark (from an open tab, etc.) into a chosen
            // folder. No source node to remove, so it is insert-only and runs
            // immediately like move — no approval step.
            handleAddBookmarkCommand(command)
        }
    }

    private func handleCloseTabCommand(
        _ command: SyncCommand,
        reconcilingExecution: Bool
    ) {
        guard let data = command.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CloseTabPayload.self, from: data) else {
            var failedCmd = command
            failedCmd.status = .refused
            failedCmd.statusReason = "Invalid close tab payload"
            failedCmd.completedAt = Date()
            pushCommandResult(failedCmd)
            return
        }

        let dummyResult = BrowserSearchResult(
            title: payload.url,
            url: payload.url,
            browserName: payload.browserName,
            type: .tab,
            timestamp: Date(),
            windowIndex: payload.windowIndex,
            tabIndex: payload.tabIndex,
            tabID: payload.tabID
        )

        let backend = BrowserTabService.shared.backend(for: payload.browserName)
        guard let backend else {
            var notFoundCmd = command
            notFoundCmd.status = .notFound
            notFoundCmd.statusReason = "Browser \(payload.browserName) is not available"
            notFoundCmd.completedAt = Date()
            pushCommandResult(notFoundCmd)
            return
        }

        if reconcilingExecution,
           !BrowserTabService.shared.remoteCloseTargetExists(payload) {
            var completedCmd = command
            completedCmd.status = .done
            completedCmd.statusReason = "Tab already absent after interrupted close"
            completedCmd.completedAt = Date()
            BrowserTabService.shared.refreshAuthoritativeLiveTabsAndPublish()
            pushCommandResult(completedCmd)
            return
        }

        if !reconcilingExecution {
            do {
                try commandJournal.markExecuting(command)
            } catch {
                logger.error("Failed to persist executing command \(command.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Execute tab close with strict safety (allowPositionalFallback: false)
        let result = backend.closeTabWithResult(dummyResult, allowPositionalFallback: false)
        var responseCmd = command
        responseCmd.completedAt = Date()

        switch result {
        case .closed:
            responseCmd.status = .done
            responseCmd.statusReason = "Tab closed on Mac"
            logger.info("Successfully closed tab remotely: url=\(payload.url, privacy: .public)")
            BrowserTabService.shared.recordClosedTabFromRemote(browserName: payload.browserName, url: payload.url, tabID: payload.tabID)
        case .notFound:
            responseCmd.status = .notFound
            responseCmd.statusReason = "Tab not found or browser not running"
            logger.info("Remote close tab not found: url=\(payload.url, privacy: .public)")
        case .refused(let reason):
            responseCmd.status = .refused
            responseCmd.statusReason = reason
            logger.info("Remote close tab refused: \(reason, privacy: .public)")
        }

        pushCommandResult(responseCmd)
    }

    /// Executes a bookmark move synchronously and immediately, with no
    /// approval gate: remove from the source browser/profile, insert into the
    /// destination, and if the insert fails, put it straight back where it
    /// came from rather than lose it silently.
    private func handleMoveBookmarkCommand(_ command: SyncCommand) {
        guard let data = command.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MoveBookmarkPayload.self, from: data) else {
            var failedCmd = command
            failedCmd.status = .refused
            failedCmd.statusReason = "Invalid move bookmark payload"
            failedCmd.completedAt = Date()
            pushCommandResult(failedCmd)
            return
        }

        var responseCmd = command
        responseCmd.completedAt = Date()

        guard let sourceBackend = BrowserTabService.shared.backend(for: payload.sourceBrowserName) else {
            responseCmd.status = .notFound
            responseCmd.statusReason = "Browser \(payload.sourceBrowserName) is not available"
            pushCommandResult(responseCmd)
            return
        }
        guard let destinationBackend = BrowserTabService.shared.backend(for: payload.destinationBrowserName) else {
            responseCmd.status = .notFound
            responseCmd.statusReason = "Browser \(payload.destinationBrowserName) is not available"
            pushCommandResult(responseCmd)
            return
        }

        let sourceResult = BrowserSearchResult(
            title: payload.url,
            url: payload.url,
            browserName: payload.sourceBrowserName,
            type: .bookmark,
            timestamp: Date(),
            bookmarkID: payload.bookmarkID,
            profileName: payload.sourceProfileName
        )

        guard let removed = sourceBackend.removeBookmarkForMove(sourceResult) else {
            responseCmd.status = .notFound
            responseCmd.statusReason = "Bookmark not found on Mac"
            pushCommandResult(responseCmd)
            return
        }

        let inserted = destinationBackend.insertBookmark(
            title: removed.title,
            url: removed.url,
            dateAdded: removed.dateAdded,
            profileName: payload.destinationProfileName,
            folderPath: payload.destinationFolderPath
        )

        if inserted {
            responseCmd.status = .done
            responseCmd.statusReason = "Bookmark moved"
            logger.info("moveBookmark: moved id=\(payload.bookmarkID ?? "-", privacy: .public) to browser=\(payload.destinationBrowserName, privacy: .public) profile=\(payload.destinationProfileName, privacy: .public)")
            pushCommandResult(responseCmd)
            return
        }

        // Destination write failed (most likely: the folder no longer exists
        // by the time this ran). Put it back rather than lose it — this
        // command has no Mac-side approval step to catch a bad write before
        // it happens, so the rollback here is that safety net instead.
        let restored = sourceBackend.insertBookmark(
            title: removed.title,
            url: removed.url,
            dateAdded: removed.dateAdded,
            profileName: payload.sourceProfileName,
            folderPath: removed.originalFolderPath
        )

        responseCmd.status = .refused
        responseCmd.statusReason = restored
            ? "Destination folder no longer exists — put it back where it was"
            : "Couldn't move it, and couldn't put it back — check your Mac"
        logger.error("moveBookmark: insert failed, restored=\(restored) id=\(payload.bookmarkID ?? "-", privacy: .public)")
        pushCommandResult(responseCmd)
    }

    /// Executes an add-bookmark request synchronously and immediately, with no
    /// approval gate: insert a brand-new bookmark (e.g. from an open tab) into
    /// the requested browser/profile/folder. There is no source to remove, so a
    /// failure has nothing to roll back — the tab keeps its open state.
    private func handleAddBookmarkCommand(_ command: SyncCommand) {
        guard let data = command.payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AddBookmarkPayload.self, from: data) else {
            var failedCmd = command
            failedCmd.status = .refused
            failedCmd.statusReason = "Invalid add bookmark payload"
            failedCmd.completedAt = Date()
            pushCommandResult(failedCmd)
            return
        }

        var responseCmd = command
        responseCmd.completedAt = Date()

        guard let backend = BrowserTabService.shared.backend(for: payload.browserName) else {
            responseCmd.status = .notFound
            responseCmd.statusReason = "Browser \(payload.browserName) is not available"
            pushCommandResult(responseCmd)
            return
        }

        let inserted = backend.insertBookmark(
            title: payload.title,
            url: payload.url,
            dateAdded: Date(),
            profileName: payload.profileName,
            folderPath: payload.folderPath
        )

        if inserted {
            responseCmd.status = .done
            responseCmd.statusReason = "Bookmark saved"
            logger.info("addBookmark: saved '\(payload.title, privacy: .public)' to browser=\(payload.browserName, privacy: .public) profile=\(payload.profileName, privacy: .public)")
            pushCommandResult(responseCmd)
            return
        }

        responseCmd.status = .refused
        responseCmd.statusReason = "Couldn't save bookmark — check the destination folder on your Mac"
        logger.error("addBookmark: insert failed title=\(payload.title, privacy: .public)")
        pushCommandResult(responseCmd)
    }

    /// Executes a remote deletion immediately, with no approval gate.
    ///
    /// Deletes were once queued for Mac-side approval (`PendingApprovalStore`);
    /// that gate is gone, and deletions from another device now apply at once.
    /// Idempotence is the safety net standing in for the old approval step: a
    /// re-delivered command re-executes a no-op (the bookmark/history entry is
    /// already gone) and the journal's settled ledger re-pushes the stored
    /// `.done` answer instead.
    private func handleDeleteCommand(_ command: SyncCommand) {
        var responseCmd = command
        responseCmd.completedAt = Date()

        guard let data = command.payloadJSON.data(using: .utf8) else {
            responseCmd.status = .refused
            responseCmd.statusReason = "Invalid delete payload"
            pushCommandResult(responseCmd)
            return
        }

        var deleted = false
        switch command.kind {
        case .deleteBookmark:
            guard let payload = try? JSONDecoder().decode(DeleteBookmarkPayload.self, from: data) else {
                responseCmd.status = .refused
                responseCmd.statusReason = "Invalid delete bookmark payload"
                pushCommandResult(responseCmd)
                return
            }
            let result = BrowserSearchResult(
                title: payload.url,
                url: payload.url,
                browserName: payload.browserName,
                type: .bookmark,
                timestamp: Date(),
                bookmarkID: payload.bookmarkID,
                profileName: payload.profileName
            )
            deleted = executeDeletion(of: result, bookmarkID: payload.bookmarkID)

        case .deleteHistoryItem:
            guard let payload = try? JSONDecoder().decode(DeleteHistoryItemPayload.self, from: data) else {
                responseCmd.status = .refused
                responseCmd.statusReason = "Invalid delete history payload"
                pushCommandResult(responseCmd)
                return
            }
            let result = BrowserSearchResult(
                title: payload.url,
                url: payload.url,
                browserName: payload.browserName,
                type: .history,
                timestamp: Date()
            )
            deleted = executeDeletion(of: result, bookmarkID: nil)

        default:
            return
        }

        // An unavailable browser means the delete could not be applied at all —
        // say `.notFound`, not `.done`, or the phone would drop its copy and the
        // deletion would look successful when nothing on the Mac changed.
        responseCmd.status = deleted ? .done : .notFound
        responseCmd.statusReason = deleted ? "Deleted on Mac" : "Browser not available to delete from"
        pushCommandResult(responseCmd)
        logger.info("Executed delete command id=\(command.id, privacy: .public) kind=\(command.kind.rawValue, privacy: .public) status=\(responseCmd.status.rawValue, privacy: .public)")
    }

    /// Applies a deletion through the same priority as the retired approval
    /// flow: the Chromium-family extension bridge first (authoritative
    /// in-browser removal), then the backend's file-level delete as fallback.
    /// Returns `false` only when the browser is not installed at all, so the
    /// caller can answer the phone honestly instead of reporting a fake `.done`.
    private func executeDeletion(of result: BrowserSearchResult, bookmarkID: String?) -> Bool {
        if result.browserName.contains("Chrome") || result.browserName.contains("Brave") || result.browserName.contains("Edge") {
            if result.type == .bookmark {
                var payload: [String: Any] = ["url": result.url]
                if let bmID = bookmarkID { payload["bookmarkId"] = bmID }
                if ExtensionBridge.shared.sendBrowserCommand(appName: result.browserName, type: "deleteBookmark", payload: payload) {
                    logger.info("Executed bookmark deletion via extension for url=\(result.url, privacy: .public)")
                    return true
                }
            } else if result.type == .history {
                if ExtensionBridge.shared.sendBrowserCommand(appName: result.browserName, type: "deleteHistoryItem", payload: ["url": result.url]) {
                    logger.info("Executed history deletion via extension for url=\(result.url, privacy: .public)")
                    return true
                }
            }
        }

        guard let backend = BrowserTabService.shared.backend(for: result.browserName) else {
            logger.warning("Delete requested for unavailable browser=\(result.browserName, privacy: .public)")
            return false
        }
        if result.type == .bookmark {
            backend.deleteBookmark(result)
        } else if result.type == .history {
            backend.deleteHistoryItem(result)
        }
        return true
    }
}
