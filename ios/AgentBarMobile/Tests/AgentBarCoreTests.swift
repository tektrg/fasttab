import AgentBarCore
import XCTest

final class AgentBarCoreTests: XCTestCase {
    private func api() throws -> AgentBarAPI { try AgentBarAPI(baseURLString: " mac.ts.net/ ", token: " tok\n") }

    private func json(_ r: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: String])
    }

    func testBaseURLNormalisesAndForcesHTTPS() throws {
        XCTAssertEqual(try api().baseURL.absoluteString, "https://mac.ts.net")
        XCTAssertEqual(try AgentBarAPI(baseURLString: "http://127.0.0.1:4712", token: "t").baseURL.absoluteString, "http://127.0.0.1:4712")
        XCTAssertThrowsError(try AgentBarAPI(baseURLString: "", token: "t"))
        XCTAssertThrowsError(try AgentBarAPI(baseURLString: "ftp://x", token: "t"))
    }

    func testAllowRequest() throws {
        let r = try api().answerRequest(requestId: "req-1", answer: .allow)
        XCTAssertEqual(r.url?.absoluteString, "https://mac.ts.net/api/hook/permission/req-1/answer")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(r.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(try json(r), ["behavior": "allow"])
    }

    func testRequestIdIsPathEscaped() throws {
        let r = try api().answerRequest(requestId: "a/b c", answer: .allow)
        XCTAssertEqual(r.url?.path(percentEncoded: true), "/api/hook/permission/a%2Fb%20c/answer")
    }

    func testActionMapping() {
        XCTAssertEqual(PermissionAnswer(actionIdentifier: "ALLOW", replyText: nil), .allow)
        XCTAssertEqual(PermissionAnswer(actionIdentifier: "DENY", replyText: nil), .deny(message: nil))
        XCTAssertEqual(PermissionAnswer(actionIdentifier: "REPLY", replyText: "  use rg  "), .deny(message: "use rg"))
        XCTAssertEqual(PermissionAnswer(actionIdentifier: "REPLY", replyText: "  "), .deny(message: nil))
        XCTAssertNil(PermissionAnswer(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", replyText: nil))
    }

    func testReplyBodyCarriesMessage() throws {
        let r = try api().answerRequest(requestId: "r", answer: .deny(message: "no, $(echo INJECTED)"))
        XCTAssertEqual(try json(r), ["behavior": "deny", "message": "no, $(echo INJECTED)"])
    }

    func testDeviceRequests() throws {
        let reg = try api().registerDeviceRequest(deviceToken: "ab01", label: "iPhone")
        XCTAssertEqual(reg.url?.path, "/api/apns/devices")
        XCTAssertEqual(try json(reg), ["deviceToken": "ab01", "label": "iPhone"])
        let del = try api().unregisterDeviceRequest(deviceToken: "ab01")
        XCTAssertEqual(del.httpMethod, "DELETE")
        XCTAssertEqual(try json(del), ["deviceToken": "ab01"])
    }

    func testHexEncoding() {
        XCTAssertEqual(DeviceTokenHex.encode(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
    }

    func testUserInfoParsing() {
        let p = AgentBarPush.permissionPrompt(from: ["requestId": "r1", "agent": "chief", "summary": "Bash: ls", "toolName": "Bash", "aps": [:]])
        XCTAssertEqual(p, .init(requestId: "r1", agent: "chief", summary: "Bash: ls", toolName: "Bash"))
        XCTAssertNil(AgentBarPush.permissionPrompt(from: ["agent": "x"]))
        XCTAssertEqual(AgentBarPush.withdrawnRequestId(from: ["withdrawn": "r1"]), "r1")
        XCTAssertNil(AgentBarPush.withdrawnRequestId(from: ["withdrawn": 3]))
    }
}
