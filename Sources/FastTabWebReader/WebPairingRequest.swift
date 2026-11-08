import Foundation

/// What the user typed into the "Pairing code" field: the 8-character code the browser shows
/// (v1.3), or an old `fasttab://pair-web?id=…&code=…` link pasted from a pre-v1.3 browser page.
public enum WebPairingRequest: Equatable, Sendable {
    case code(String)
    case link(id: String, code: String)

    public static let codeLength = 8

    /// nil when the input is neither a full code nor a usable link.
    public init?(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme == "fasttab" {
            let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value ?? "" }
            let id = value("id"), code = Self.normalize(value("code"))
            guard !id.isEmpty, code.count == Self.codeLength else { return nil }
            self = .link(id: id, code: code)
            return
        }
        let code = Self.normalize(trimmed)
        guard code.count == Self.codeLength else { return nil }
        self = .code(code)
    }

    /// Users type codes: ignore case, spaces and dashes (same rule as the server).
    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    public func approve(with api: WebReaderAPI) async throws {
        switch self {
        case .code(let code): try await api.approvePairing(code: code)
        case .link(let id, let code): try await api.approvePairing(id: id, code: code)
        }
    }
}
