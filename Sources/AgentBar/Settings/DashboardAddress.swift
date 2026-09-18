import Foundation

/// The rule for what counts as a usable dashboard address, shared by the
/// Settings field and the launch-time read of the saved value.
enum DashboardAddress {
    enum Validation: Equatable {
        case valid(URL)
        /// Plain-English reason, safe to show under the field.
        case invalid(String)
    }

    static func validate(_ text: String) -> Validation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("Enter the dashboard address, like \(DashboardEndpoint.defaultBaseURL.absoluteString).")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .invalid("That doesn't look like a web address. Start it with http:// or https://.")
        }
        guard scheme == "http" || scheme == "https" else {
            return .invalid("Only http:// and https:// addresses work.")
        }
        guard url.host != nil else {
            return .invalid("The address needs a host, like 127.0.0.1:4711.")
        }
        return .valid(url)
    }
}
