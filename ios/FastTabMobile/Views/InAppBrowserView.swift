import SwiftUI
import SafariServices

public struct InAppBrowserView: UIViewControllerRepresentable {
    public let url: URL
    public let title: String?
    public var entersReaderIfAvailable: Bool = true

    public init(url: URL, title: String? = nil, entersReaderIfAvailable: Bool = true) {
        self.url = url
        self.title = title
        self.entersReaderIfAvailable = entersReaderIfAvailable
    }

    public func makeUIViewController(context: Context) -> SFSafariViewController {
        LastOpenedStore.shared.recordOpened(url: url, title: title)

        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = entersReaderIfAvailable
        configuration.barCollapsingEnabled = true

        let safariVC = SFSafariViewController(url: url, configuration: configuration)
        safariVC.dismissButtonStyle = .close
        safariVC.preferredControlTintColor = UIColor(DS.Tint.action)
        return safariVC
    }

    public func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
