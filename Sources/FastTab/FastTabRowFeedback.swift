import Foundation

/// What a row action tells the user: a short success toast, or a failure that stays in the
/// shared persistent error notice (`CommandBarErrorNotice`, drawn where the toast goes) until ✕ or Esc.
enum FastTabRowFeedback: Equatable {
    case toast(String)
    case error(String)

    static let sentToList = FastTabRowFeedback.toast("Sent to FastTab List")
    static let cannotAddLink = FastTabRowFeedback.error("Can't add this link")

    static func sendToList(saved: Bool) -> FastTabRowFeedback {
        saved ? sentToList : cannotAddLink
    }

    static func moveToBookmarks(folderLabel: String?) -> FastTabRowFeedback {
        folderLabel.map { .toast("Moved to \($0)") } ?? .error("Couldn't add the bookmark")
    }
}

/// The error notice hangs outside the bar, so a click on its ✕ or the pointer resting on it
/// must not count as "outside" (which would close the bar).
enum FastTabErrorNoticeHit {
    /// SwiftUI window coordinates (top-left origin) → screen coordinates (bottom-left origin).
    static func screenRect(of rectInWindow: CGRect, windowFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + rectInWindow.minX, y: windowFrame.maxY - rectInWindow.maxY,
               width: rectInWindow.width, height: rectInWindow.height)
    }

    static func contains(_ screenPoint: CGPoint, noticeInWindow: CGRect?, windowFrame: CGRect) -> Bool {
        guard let noticeInWindow else { return false }
        return screenRect(of: noticeInWindow, windowFrame: windowFrame).contains(screenPoint)
    }
}
