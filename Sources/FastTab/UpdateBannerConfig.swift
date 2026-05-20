import SwiftUI

struct UpdateBannerConfig {
    let icon: String
    let tint: Color
    let message: String
    let actionTitle: String
    let dismissable: Bool
}

func updateBannerConfig(_ status: UpdateService.UpdateStatus) -> UpdateBannerConfig? {
    switch status {
    case .idle, .checking:
        return nil
    case .available(let version, let notes):
        let trail = notes.map { " \($0)" } ?? ""
        return UpdateBannerConfig(
            icon: "arrow.down.circle.fill",
            tint: .blue,
            message: "FastTab \(version) is available.\(trail)",
            actionTitle: "Update",
            dismissable: true
        )
    case .downloading(let progress):
        let pct = Int((progress * 100).rounded())
        return UpdateBannerConfig(
            icon: "arrow.down.circle",
            tint: .blue,
            message: "Downloading update... \(pct)%",
            actionTitle: "Cancel",
            dismissable: false
        )
    case .extracting:
        return UpdateBannerConfig(
            icon: "arrow.down.circle",
            tint: .blue,
            message: "Preparing update...",
            actionTitle: "Cancel",
            dismissable: false
        )
    case .readyToRestart(let version):
        return UpdateBannerConfig(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            tint: .green,
            message: "FastTab \(version) is ready.",
            actionTitle: "Restart to Update",
            dismissable: true
        )
    case .installing:
        return UpdateBannerConfig(
            icon: "arrow.triangle.2.circlepath.circle",
            tint: .green,
            message: "Installing update...",
            actionTitle: "Installing",
            dismissable: false
        )
    case .upToDate:
        return nil
    case .error(let message):
        return UpdateBannerConfig(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            message: "Update failed: \(message)",
            actionTitle: "Retry",
            dismissable: true
        )
    }
}
