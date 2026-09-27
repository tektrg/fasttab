import Foundation

/// Remembered answer to "Also close this tab?" after an inline Bookmark tap.
/// `.ask` (default) shows the prompt; the others act in one tap. Stored as a
/// raw string so views can bind it with `@AppStorage(Self.defaultsKey)`.
enum TabBookmarkClosePreference: String {
    case ask
    case bookmarkAndClose
    case bookmarkOnly

    static let defaultsKey = "FastTabMobile.tabBookmarkClosePreferenceV1"
}
