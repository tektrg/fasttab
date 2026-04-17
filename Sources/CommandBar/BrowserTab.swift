import Foundation

struct BrowserTab: Identifiable, Codable, Hashable {
    var id: String { "\(appName)-\(windowIndex)-\(tabIndex)-\(url)" }
    let title: String
    let url: String
    let windowIndex: Int
    let tabIndex: Int
    let appName: String
    var lastActive: Date = Date()
}
