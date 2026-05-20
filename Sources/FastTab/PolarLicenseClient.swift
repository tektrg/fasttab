import Foundation

@MainActor
protocol PolarLicenseClient {
    func activate(
        key: String,
        organizationID: String,
        label: String,
        conditions: [String: Int],
        meta: [String: String]
    ) async throws -> PolarActivationResponse

    func validate(
        key: String,
        organizationID: String,
        activationID: String,
        conditions: [String: Int]
    ) async throws -> PolarLicenseKey
}

enum PolarLicenseClientError: Error, LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(Int)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Polar returned an unreadable response."
        case .requestFailed(let statusCode):
            switch statusCode {
            case 403:
                return "Activation limit reached or license cannot be activated."
            case 404:
                return "License key was not found."
            case 422:
                return "License key details were not accepted."
            default:
                return "Polar request failed with status \(statusCode)."
            }
        case .invalidDate(let value):
            return "Polar returned an unsupported date: \(value)."
        }
    }
}

@MainActor
final class CustomerPortalPolarLicenseClient: PolarLicenseClient {
    private let apiBaseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(apiBaseURL: URL, session: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom(PolarDateDecoder.decode)
    }

    func activate(
        key: String,
        organizationID: String,
        label: String,
        conditions: [String: Int],
        meta: [String: String]
    ) async throws -> PolarActivationResponse {
        let body = ActivateRequest(
            key: key,
            organizationID: organizationID,
            label: label,
            conditions: conditions,
            meta: meta
        )
        return try await post(path: "/v1/customer-portal/license-keys/activate", body: body)
    }

    func validate(
        key: String,
        organizationID: String,
        activationID: String,
        conditions: [String: Int]
    ) async throws -> PolarLicenseKey {
        let body = ValidateRequest(
            key: key,
            organizationID: organizationID,
            activationID: activationID,
            conditions: conditions
        )
        return try await post(path: "/v1/customer-portal/license-keys/validate", body: body)
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody
    ) async throws -> ResponseBody {
        let url = apiBaseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.snakeCase.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PolarLicenseClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PolarLicenseClientError.requestFailed(httpResponse.statusCode)
        }
        return try decoder.decode(ResponseBody.self, from: data)
    }

    private struct ActivateRequest: Encodable {
        let key: String
        let organizationID: String
        let label: String
        let conditions: [String: Int]
        let meta: [String: String]
    }

    private struct ValidateRequest: Encodable {
        let key: String
        let organizationID: String
        let activationID: String
        let conditions: [String: Int]
    }
}

enum PolarDateDecoder {
    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
            return date
        }

        throw PolarLicenseClientError.invalidDate(value)
    }
}

private extension JSONEncoder {
    static var snakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
