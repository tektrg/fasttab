import SwiftUI
import AppKit

extension ContentView {
    func clearKeyboardSwipe() {
        keyboardSwipeResultID = nil
        keyboardSwipeAction = nil
    }

    func resetPointerSwipe(animated: Bool) {
        let update = {
            pointerSwipeResultID = nil
            pointerSwipeOffset = 0
            pointerSwipeAction = nil
            didConfirmPointerSwipe = false
            isPointerSwipeGestureActive = false
        }

        if animated {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88), update)
        } else {
            update()
        }
    }

    func clearPointerSwipeSuppression() {
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = nil
        suppressPointerSwipeUntilGestureEnds = false
    }

    private func suppressPointerSwipeUntilCurrentGestureEnds() {
        suppressPointerSwipeUntilGestureEnds = true
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                suppressPointerSwipeUntilGestureEnds = false
                pointerSwipeSuppressionTask = nil
            }
        }
    }

    func handlePointerScrollSwipe(_ event: NSEvent) -> Bool {
        guard appState.isVisible else { return false }

        let ended = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
        let cancelled = event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled)
        if suppressPointerSwipeUntilGestureEnds {
            if ended || cancelled {
                clearPointerSwipeSuppression()
            }
            return true
        }

        if ended || cancelled {
            return finishPointerScrollSwipe(cancelled: cancelled)
        }

        let deltaX = normalizedHorizontalScrollDelta(from: event)
        let deltaY = CGFloat(event.scrollingDeltaY)
        let absX = abs(deltaX)
        let absY = abs(deltaY)

        if pointerSwipeResultID != nil, absX < 3, absY > 3 {
            resetPointerSwipe(animated: true)
            return false
        }

        if pointerSwipeResultID == nil {
            guard absX > 3, absX > absY * 1.35, let hoveredResultID else { return false }
            pointerSwipeResultID = hoveredResultID
            didConfirmPointerSwipe = false
            isPointerSwipeGestureActive = true
        }

        guard !didConfirmPointerSwipe else { return true }

        let nextOffset = max(
            -ResultSwipeMetrics.maximumOffset,
             min(ResultSwipeMetrics.maximumOffset, pointerSwipeOffset + deltaX)
        )
        pointerSwipeOffset = nextOffset

        guard let nextAction = swipeAction(for: nextOffset) else {
            pointerSwipeAction = nil
            return true
        }

        if abs(nextOffset) >= ResultSwipeMetrics.confirmDistance {
            didConfirmPointerSwipe = true
            confirmPointerSwipe(nextAction)
        } else if abs(nextOffset) >= ResultSwipeMetrics.revealDistance {
            pointerSwipeAction = nextAction
            if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
        }

        return true
    }

    private func finishPointerScrollSwipe(cancelled: Bool) -> Bool {
        guard pointerSwipeResultID != nil else { return false }
        isPointerSwipeGestureActive = false
        guard !didConfirmPointerSwipe else {
            resetPointerSwipe(animated: false)
            return true
        }

        if cancelled || abs(pointerSwipeOffset) < ResultSwipeMetrics.revealDistance {
            resetPointerSwipe(animated: true)
            return true
        }

        let restingAction = swipeAction(for: pointerSwipeOffset)
        pointerSwipeAction = restingAction
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            pointerSwipeOffset = (restingAction?.sign ?? 0) * ResultSwipeMetrics.revealDistance
        }
        return true
    }

    private func confirmPointerSwipe(_ action: ResultSwipeAction) {
        let results = displayedResults
        guard let pointerSwipeResultID,
              let result = results.first(where: { $0.id == pointerSwipeResultID }) else {
            resetPointerSwipe(animated: true)
            return
        }

        switch action {
        case .delete:
            suppressPointerSwipeUntilCurrentGestureEnds()
            performRemove(result)
        case .copy:
            suppressPointerSwipeUntilCurrentGestureEnds()
            performCopyLink(result)
        }
    }

    private func swipeAction(for offset: CGFloat) -> ResultSwipeAction? {
        if offset <= -1 { return .delete }
        if offset >= 1 { return .copy }
        return nil
    }

    private func normalizedHorizontalScrollDelta(from event: NSEvent) -> CGFloat {
        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        return -CGFloat(event.scrollingDeltaX) * directionMultiplier
    }

    func handleKeyboardSwipe(_ action: ResultSwipeAction) {
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex),
              let result = items[appState.selectedIndex].result else { return }

        if keyboardSwipeResultID == result.id, keyboardSwipeAction == action {
            switch action {
            case .delete:
                performRemove(result)
            case .copy:
                performCopyLink(result)
            }
            return
        }

        if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            keyboardSwipeResultID = result.id
            keyboardSwipeAction = action
        }
        isSearchFocused = false
    }

    private func performCopyLink(_ result: BrowserSearchResult) {
        appState.browserService.copyLinkToClipboard(result)
        showToastAndDismiss("Link copied")
    }

    private func performRemove(_ result: BrowserSearchResult) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            appState.browserService.remove(result)
        }
    }

    private func showToastAndDismiss(_ message: String) {
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
}
