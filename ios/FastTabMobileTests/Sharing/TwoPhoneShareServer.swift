import Foundation
import IndieSharing
import os

/// A fake theindie-api shared by two signed-in phones: what one uploads, the other's inbox
/// lists. Covers sign-in, device registration, recipient devices, the share upload, the
/// inbox with its share downloads, and comments. Each person signs in with their own
/// identity token and is told apart by their session token.
///
/// Installed as the stub server's fallback. Every route checks `app` against `appSlug`, like
/// the real server's app registry (`APPS`), so a wrong slug fails the test.
final class TwoPhoneShareServer: Sendable {
    struct Person: Sendable {
        let userID: UUID
        let displayName: String
        /// Stands in for Apple's identity token: sign-in with it signs in as this person.
        var identityToken: String { "apple-\(displayName)" }
        var sessionToken: String { "session-\(displayName)" }
    }

    private struct RegisteredDevice {
        let userID: UUID
        let deviceID: UUID
        let publicKey: String
        let app: String
    }

    private struct UploadedShare {
        let senderUserID: UUID
        let createBody: Data
        var content = Data()
        var attachments: [String: Data] = [:]
    }

    private struct State {
        var devices: [RegisteredDevice] = []
        var shares: [String: UploadedShare] = [:]
        /// Per receiving device (lowercased id): inbox items as JSON, in arrival order.
        var inboxes: [String: [String]] = [:]
        var nextCommentSeq = 1
        var conversationCount = 0
    }

    let appSlug: String
    private let people: [Person]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(on server: StubAccountServer, appSlug: String, people: [Person]) {
        self.appSlug = appSlug
        self.people = people
        server.fallback { [self] request in self.answer(request) }
    }

    // MARK: - Routing

    private func answer(_ request: StubAccountServer.RecordedRequest) -> StubAccountServer.StubResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        if request.method == "POST", parts == ["v1", "auth", "apple"] { return signIn(request) }
        guard let caller = caller(of: request) else { return .error(401, code: "unauthorized") }
        switch (request.method, Array(parts.dropFirst())) {
        case ("POST", ["devices"]):
            return registerDevice(request, for: caller)
        case ("GET", let path) where path.count == 3 && path[0] == "users" && path[2] == "devices":
            return deviceList(userID: path[1], app: request.query["app"])
        case ("POST", ["shares"]):
            return createShare(request.body, sender: caller)
        case ("PUT", let path) where path.count == 3 && path[0] == "shares" && path[2] == "content":
            return storeUpload(shareID: path[1]) { $0.content = request.body }
        case ("PUT", let path) where path.count == 4 && path[0] == "shares" && path[2] == "attachments":
            return storeUpload(shareID: path[1]) { $0.attachments[path[3].lowercased()] = request.body }
        case ("POST", let path) where path.count == 3 && path[0] == "shares" && path[2] == "complete":
            return completeShare(shareID: path[1])
        case ("GET", ["inbox"]):
            return inboxPage(deviceID: request.query["deviceID"] ?? "", cursor: request.query["cursor"])
        case ("GET", let path) where path.count == 3 && path[0] == "shares" && path[2] == "content":
            return download(shareID: path[1]) { $0.content }
        case ("GET", let path) where path.count == 4 && path[0] == "shares" && path[2] == "attachments":
            return download(shareID: path[1]) { $0.attachments[path[3].lowercased()] }
        case ("POST", let path) where path.count == 3 && path[0] == "shares" && path[2] == "comments":
            return createComment(request.body, author: caller)
        default:
            return .error(404, code: "not_found")
        }
    }

    private func caller(of request: StubAccountServer.RecordedRequest) -> Person? {
        let token = request.headers["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
        return people.first { $0.sessionToken == token }
    }

    // MARK: - Account

    private func signIn(_ request: StubAccountServer.RecordedRequest) -> StubAccountServer.StubResponse {
        let body = request.jsonBody()
        guard body["app"] as? String == appSlug else { return .error(400, code: "unknown_app") }
        guard let person = people.first(where: { $0.identityToken == body["identityToken"] as? String }) else {
            return .error(401, code: "invalid_identity_token")
        }
        return .json(200, json([
            "token": person.sessionToken, "expiresAt": Self.nowMilliseconds + 86_400_000, "isNewAccount": false,
            "user": [
                "userID": wireID(person.userID), "displayName": person.displayName, "avatarURL": NSNull(),
                "email": "\(person.displayName.lowercased())@example.com", "isPrivateEmail": false,
                "createdAt": Self.nowMilliseconds,
            ] as [String: Any],
        ]))
    }

    private func registerDevice(_ request: StubAccountServer.RecordedRequest, for person: Person) -> StubAccountServer.StubResponse {
        let body = request.jsonBody()
        guard body["app"] as? String == appSlug else { return .error(400, code: "unknown_app") }
        guard let publicKey = body["publicKey"] as? String else { return .error(400, code: "invalid_field") }
        let device = RegisteredDevice(userID: person.userID, deviceID: UUID(), publicKey: publicKey, app: appSlug)
        state.withLock { $0.devices.append(device) }
        return .json(201, json([
            "deviceID": wireID(device.deviceID), "publicKey": publicKey, "app": appSlug, "platform": "ios",
            "createdAt": Self.nowMilliseconds,
        ]))
    }

    private func deviceList(userID: String, app: String?) -> StubAccountServer.StubResponse {
        let devices = state.withLock { state in
            state.devices.filter { wireID($0.userID) == userID.lowercased() && $0.app == app }
        }
        return .json(200, json([
            "userID": userID.lowercased(),
            "devices": devices.map { ["deviceID": wireID($0.deviceID), "publicKey": $0.publicKey, "app": $0.app] },
        ]))
    }

    // MARK: - Shares

    private func createShare(_ body: Data, sender: Person) -> StubAccountServer.StubResponse {
        let fields = SharedNotesFixtures.object(body)
        guard fields["app"] as? String == appSlug else { return .error(400, code: "unknown_app") }
        let shareID = (fields["shareID"] as? String ?? "").lowercased()
        state.withLock { $0.shares[shareID] = UploadedShare(senderUserID: sender.userID, createBody: body) }
        return .json(201, SharedNotesFixtures.shareRecordJSON(fromCreateBody: body))
    }

    private func storeUpload(shareID: String, _ update: (inout UploadedShare) -> Void) -> StubAccountServer.StubResponse {
        state.withLock { state in
            guard var share = state.shares[shareID.lowercased()] else { return .error(404, code: "share_not_found") }
            update(&share)
            state.shares[shareID.lowercased()] = share
            return .noContent
        }
    }

    /// Completing makes the share visible: one inbox item per recipient device.
    private func completeShare(shareID: String) -> StubAccountServer.StubResponse {
        state.withLock { state in
            guard let share = state.shares[shareID.lowercased()] else { return .error(404, code: "share_not_found") }
            let sender = people.first { $0.userID == share.senderUserID }
            let recipients = SharedNotesFixtures.object(share.createBody)["recipients"] as? [[String: Any]] ?? []
            for deviceID in recipients.compactMap({ ($0["deviceID"] as? String).flatMap(UUID.init(uuidString:)) }) {
                state.inboxes[wireID(deviceID), default: []].append(SharedNotesFixtures.inboxItemJSON(
                    fromCreateBody: share.createBody, for: deviceID, senderID: share.senderUserID,
                    senderName: sender?.displayName))
            }
            return .json(200, SharedNotesFixtures.shareRecordJSON(fromCreateBody: share.createBody, status: "completed"))
        }
    }

    private func download(shareID: String, _ bytes: (UploadedShare) -> Data?) -> StubAccountServer.StubResponse {
        state.withLock { state in
            guard let data = state.shares[shareID.lowercased()].flatMap(bytes) else { return .error(404, code: "not_found") }
            return .init(status: 200, body: data, headers: [:])
        }
    }

    /// Everything after `cursor` (an item count); no cursor = the full list.
    private func inboxPage(deviceID: String, cursor: String?) -> StubAccountServer.StubResponse {
        let items = state.withLock { $0.inboxes[deviceID.lowercased()] ?? [] }
        let start = min(cursor.flatMap(Int.init) ?? 0, items.count)
        return .json(200, SharedNotesFixtures.inboxPageJSON(items: Array(items[start...]), nextCursor: String(items.count)))
    }

    // MARK: - Comments

    /// One `comment_added` item per sealed-for device. A first comment opens the thread.
    private func createComment(_ body: Data, author: Person) -> StubAccountServer.StubResponse {
        guard let envelope = try? CommentEnvelope(jsonData: body) else { return .error(400, code: "invalid_body") }
        return state.withLock { state in
            let conversationID = envelope.conversationID ?? {
                state.conversationCount += 1
                return "conv-\(state.conversationCount)"
            }()
            for recipient in envelope.recipients {
                let event: [String: Any] = [
                    "seq": state.nextCommentSeq, "kind": "comment_added", "shareID": wireID(envelope.shareID),
                    "conversationID": conversationID, "commentID": wireID(envelope.commentID),
                    "authorUserID": wireID(author.userID), "createdAt": Self.nowMilliseconds,
                    "content": Base64URL.encode(envelope.content),
                    "encapsulatedKey": Base64URL.encode(recipient.encapsulatedKey),
                    "wrappedKey": Base64URL.encode(recipient.wrappedKey),
                ]
                state.nextCommentSeq += 1
                state.inboxes[wireID(recipient.deviceID), default: []].append(json(event))
            }
            return .json(201, json([
                "commentID": wireID(envelope.commentID), "conversationID": conversationID, "createdAt": Self.nowMilliseconds,
            ]))
        }
    }

    // MARK: - JSON

    private static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func wireID(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func json(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}
