import SwiftUI
import AppKit
import IndieCommandBar

extension ContentView {
    func clearKeyboardSwipe() {
        keyboardSwipe.clear()
    }

    func resetPointerSwipe(animated: Bool) {
        if animated {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) { pointerSwipe.reset() }
        } else {
            pointerSwipe.reset()
        }
    }

    func clearPointerSwipeSuppression() {
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = nil
        pointerSwipe.liftSuppression()
    }

    /// The shared engine suppresses the rest of a confirmed gesture; this lifts
    /// it after 450 ms in case the gesture's end event never arrives.
    private func startPointerSwipeSuppressionTimer() {
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                pointerSwipe.liftSuppression()
                pointerSwipeSuppressionTask = nil
            }
        }
    }

    func handlePointerScrollSwipe(_ event: NSEvent) -> Bool {
        guard appState.isVisible else { return false }

        let ended = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
        let cancelled = event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled)

        guard pointerSwipe.canTrack(isEnabled: env.isRowSwipeEnabled(), hoveredRowID: hoveredResultID) else {
            return handleViewFlick(event)
        }

        let step = pointerSwipe.track(
            deltaX: normalizedHorizontalScrollDelta(from: event),
            deltaY: CGFloat(event.scrollingDeltaY),
            ended: ended,
            cancelled: cancelled,
            hoveredRowID: hoveredResultID
        )
        switch step {
        case .passThrough:
            return false
        case .consumed:
            return true
        case .revealed:
            if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
            return true
        case .reset(let animated, let consumed):
            resetPointerSwipe(animated: animated)
            return consumed
        case .settle:
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) { pointerSwipe.settle() }
            return true
        case .confirm(let rowID, let edge):
            guard let result = displayedResults.first(where: { $0.id == rowID }) else {
                pointerSwipe.liftSuppression()
                resetPointerSwipe(animated: true)
                return true
            }
            startPointerSwipeSuppressionTimer()
            performSwipeAction(edge, on: result)
            return true
        case .suppressionLifted:
            clearPointerSwipeSuppression()
            return true
        }
    }

    /// Horizontal scroll with no row swipe in play flicks between views.
    private func handleViewFlick(_ event: NSEvent) -> Bool {
        let result = flickDetector.handleEvent(
            deltaX: normalizedHorizontalScrollDelta(from: event),
            deltaY: CGFloat(event.scrollingDeltaY),
            began: event.phase.contains(.began),
            touchEnded: event.phase.contains(.ended),
            momentumEnded: event.momentumPhase.contains(.ended),
            cancelled: event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled),
            isMomentum: !event.momentumPhase.isEmpty,
            currentView: viewStore.activeView,
            orderedViews: viewStore.availableViews
        )
        if let nextView = result.target {
            viewStore.selectView(nextView)
        }
        return result.consumed
    }

    /// Fast Tab's perform hook for the shared swipe engine.
    func performSwipeAction(_ edge: CommandBarSwipeEdge, on result: BrowserSearchResult) {
        switch FastTabSwipeActions.kind(for: edge) {
        case .remove: performRemove(result)
        case .copyLink: performCopyLink(result)
        }
    }

    private func normalizedHorizontalScrollDelta(from event: NSEvent) -> CGFloat {
        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        return -CGFloat(event.scrollingDeltaX) * directionMultiplier
    }

    func handleKeyboardSwipe(_ edge: CommandBarSwipeEdge) {
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex),
              let result = items[appState.selectedIndex].result else { return }

        if case .perform(let edge) = keyboardSwipe.step(for: edge, on: result.id) {
            performSwipeAction(edge, on: result)
            return
        }

        if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            keyboardSwipe.reveal(edge, on: result.id)
        }
        isSearchFocused = false
    }

    func performCopyLink(_ result: BrowserSearchResult) {
        appState.browserService.copyLinkToClipboard(result)
        showToastAndDismiss(FastTabSwipeActions.copiedToastText)
    }

    /// A Stack slot's copy action (⋯ › Copy URL, ⌘C): same toast as a result row.
    func performCopySlotURL(_ slot: OrderedTabSlot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(slot.url, forType: .string)
        showToastAndDismiss(FastTabSwipeActions.copiedToastText)
    }

    /// Choreographed in three overlapping beats: the content keeps sliding
    /// in the swipe's direction (`SwipeableResultRow.contentOffset`), the
    /// checkmark already on screen follows a beat behind and zooms/fades
    /// (`RemovalConfirmationIcon`), and only then does the row actually leave
    /// the list — starting a little before the checkmark finishes so the
    /// rows below are already sliding up to close the gap while it's still
    /// fading, rather than everything happening in strict sequence.
    ///
    /// Not resetting the swipe-reveal state (`clearKeyboardSwipe`/
    /// `resetPointerSwipe`) until this final step is what lets the content's
    /// offset continue smoothly into the exit slide instead of snapping back
    /// to rest first. And starting `rowRemovalExit` in its own call — not
    /// bundled into the same transaction as removing the row from the data
    /// source — is what gives SwiftUI a real intermediate render to animate
    /// from; doing both at once would make the outgoing row's transition
    /// play from a snapshot taken *before* `rowRemovalExit` ever matched
    /// it, and the confirmation icon would never render.
    func performRemove(_ result: BrowserSearchResult) {
        let resultID = result.id
        // Restart the timer even for the same row, so a double click can't
        // end its exit slide early.
        closingResultTask?.cancel()
        if let pendingID = rowRemovalExit.begin(resultID) {
            if let pendingResult = displayedResults.first(where: { $0.id == pendingID }) {
                appState.browserService.remove(pendingResult)
            }
        }
        closingResultTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                clearKeyboardSwipe()
                resetPointerSwipe(animated: false)
                // The row stays in its exited position (`rowRemovalExit`)
                // while it leaves the list. Clearing it here instead would
                // slide it back to rest before it vanished.
                // Matches the surface's own resize curve (ContentView's
                // `.animation(.easeOut(duration: 0.12), value: surfaceSize)`)
                // so the panel doesn't finish shrinking — clipping the list —
                // before the rows below the deleted one finish sliding up to
                // fill the gap.
                withAnimation(.spring(response: 0.16, dampingFraction: 0.92)) {
                    appState.browserService.remove(result)
                }
            }
            // Let the collapse finish before releasing the row. If it is
            // still listed (the close failed), releasing slides it back.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let stillListed = displayedResults.contains { $0.id == resultID }
                rowRemovalExit.finish(resultID, stillListed: stillListed)
            }
        }
    }

    func showToastAndDismiss(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            toastMessage = message
        }

        toastDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.hideCommandBar()
                clearKeyboardSwipe()
                clearPointerSwipeSuppression()
                resetPointerSwipe(animated: false)
                withAnimation(.easeOut(duration: 0.16)) {
                    toastMessage = nil
                }
            }
        }
    }

    func showToast(_ message: String, duration: Duration = .milliseconds(1500)) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            toastMessage = message
        }

        toastDismissTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.16)) {
                    toastMessage = nil
                }
            }
        }
    }
}
