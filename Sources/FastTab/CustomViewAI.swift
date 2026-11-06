import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence (Foundation Models) gate for custom views' "AI filter".
/// The package targets macOS 14, so every use of the framework is behind
/// `canImport` + `#available`; callers only ever see `isAvailable`.
/// The builder disables the AI field when this is false, and the page shows
/// structured results + a banner (owner decision: no keyword fallback).
enum CustomViewAI {
    /// True when the on-device model can run now (macOS 26+, Apple
    /// Intelligence on and its model downloaded). Cheap; re-read it rather
    /// than caching — the user can turn Apple Intelligence on mid-session.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Shown wherever the AI filter can't run.
    static let unavailableMessage = "Requires Apple Intelligence (macOS 26)"
}
