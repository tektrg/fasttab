import Foundation
import SwiftUI
import OSLog

struct VersionManifest: Decodable {
    let version: String
    let download_url: String
    let release_notes: String?
    let mandatory: Bool?
}

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var status: UpdateStatus = .idle

    enum UpdateStatus: Equatable {
        case idle
        case checking
        case available(String, URL, String?) // version, downloadURL, releaseNotes
        case upToDate
        case error(String)
    }

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "UpdateService")
    private let manifestURL = URL(string: "https://fasttab.theindie.app/version.json")!

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates(manual: Bool = false) {
        if case .checking = status, !manual {
            return
        }

        status = .checking
        logger.info("Checking for updates. Current version: \(self.currentVersion, privacy: .public)")

        var request = URLRequest(url: manifestURL)
        request.setValue(currentVersion, forHTTPHeaderField: "X-FastTab-Version")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                self?.handleResponse(data: data, response: response, error: error, manual: manual)
            }
        }.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, manual: Bool) {
        if let error {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = manual ? .error(error.localizedDescription) : .idle
            return
        }

        guard let data else {
            status = manual ? .error("Empty response from server.") : .idle
            return
        }

        do {
            let manifest = try JSONDecoder().decode(VersionManifest.self, from: data)

            guard let remoteVersion = normalizeVersion(manifest.version),
                  let localVersion = normalizeVersion(currentVersion) else {
                status = manual ? .error("Invalid version format.") : .idle
                return
            }

            if versionCompare(remoteVersion, localVersion) > 0 {
                logger.info("Update available: \(manifest.version, privacy: .public)")
                guard let url = URL(string: manifest.download_url) else {
                    status = manual ? .error("Invalid download URL.") : .idle
                    return
                }
                status = .available(manifest.version, url, manifest.release_notes)
            } else {
                logger.info("App is up to date.")
                status = manual ? .upToDate : .idle
            }
        } catch {
            logger.error("Failed to decode manifest: \(error.localizedDescription, privacy: .public)")
            status = manual ? .error("Invalid server response.") : .idle
        }
    }

    func openDownloadURL() {
        if case .available(_, let url, _) = status {
            NSWorkspace.shared.open(url)
        }
    }

    func dismiss() {
        status = .idle
    }

    /// Turns "1.2.3" into [1, 2, 3] for numeric comparison.
    private func normalizeVersion(_ string: String) -> [Int]? {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// Compares two version arrays lexicographically. Returns >0 if a > b, <0 if a < b, 0 if equal.
    private func versionCompare(_ a: [Int], _ b: [Int]) -> Int {
        let maxCount = max(a.count, b.count)
        for i in 0..<maxCount {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv {
                return av - bv
            }
        }
        return 0
    }
}
