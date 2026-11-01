import AgentBarCore
import XCTest

final class WebRoutesTests: XCTestCase {
    private let base = URL(string: "https://mac.ts.net")!

    func testSafePathAcceptsOnlySameOriginPaths() {
        XCTAssertEqual(WebRoutes.safePath("/?tab=feedback"), "/?tab=feedback")
        XCTAssertEqual(WebRoutes.safePath("/"), "/")
        for bad: Any? in ["//evil.com/x", "/\\evil.com", "https://evil.com", "evil", "", nil, 42, "/a\nb"] {
            XCTAssertNil(WebRoutes.safePath(bad), "\(String(describing: bad))")
        }
    }

    func testURLBuilding() {
        XCTAssertEqual(WebRoutes.url(base: base, path: "/?tab=agents&row=1").absoluteString, "https://mac.ts.net/?tab=agents&row=1")
        XCTAssertEqual(WebRoutes.url(base: base, path: "//evil.com"), base)
        XCTAssertEqual(WebRoutes.url(base: base, path: nil), base)
        XCTAssertEqual(WebRoutes.url(base: base, path: "/@evil.com").host, "mac.ts.net")
    }

    func testSameOrigin() {
        XCTAssertTrue(WebRoutes.isSameOrigin(URL(string: "https://MAC.ts.net:443/x")!, base: base))
        XCTAssertFalse(WebRoutes.isSameOrigin(URL(string: "http://mac.ts.net/x")!, base: base))
        XCTAssertFalse(WebRoutes.isSameOrigin(URL(string: "https://mac.ts.net:8443/")!, base: base))
        XCTAssertFalse(WebRoutes.isSameOrigin(URL(string: "https://mac.ts.net.evil.com/")!, base: base))
        XCTAssertTrue(WebRoutes.isSameOrigin(scheme: "https", host: "mac.ts.net", port: 0, base: base))
        XCTAssertFalse(WebRoutes.isSameOrigin(scheme: "https", host: "evil.com", port: 0, base: base))
    }

    func testLoginPageDetection() {
        XCTAssertTrue(WebRoutes.isLoginPage(URL(string: "https://mac.ts.net/remote/login")!, base: base))
        XCTAssertFalse(WebRoutes.isLoginPage(URL(string: "https://evil.com/remote/login")!, base: base))
        XCTAssertFalse(WebRoutes.isLoginPage(base, base: base))
    }

    func testLoginRequest() throws {
        let r = try AgentBarAPI(baseURLString: "mac.ts.net", token: "tok").loginRequest()
        XCTAssertEqual(r.url?.absoluteString, "https://mac.ts.net/remote/login")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertNil(r.value(forHTTPHeaderField: "Origin"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["token": "tok"])
    }

    func testSessionCookieParsing() {
        let url = URL(string: "https://mac.ts.net/remote/login")!
        let ok = ["Set-Cookie": "agentbar_remote_session=abc; Path=/; HttpOnly; SameSite=Strict; Max-Age=60; Secure"]
        let cookie = WebRoutes.sessionCookie(headers: ok, url: url)
        XCTAssertEqual(cookie?.value, "abc")
        XCTAssertEqual(cookie?.domain, "mac.ts.net")
        XCTAssertNil(WebRoutes.sessionCookie(headers: ["Set-Cookie": "other=1"], url: url))
        XCTAssertNil(WebRoutes.sessionCookie(headers: [:], url: url))
    }
}
