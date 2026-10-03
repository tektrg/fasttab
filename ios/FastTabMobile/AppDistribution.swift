import Foundation

/// How this build reached the device, for gating beta features.
enum AppDistribution {
    /// TestFlight installs carry a sandbox App Store receipt; App Store installs don't.
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    static var isDebugOrTestFlight: Bool {
        #if DEBUG
        return true
        #else
        return isTestFlight
        #endif
    }
}
