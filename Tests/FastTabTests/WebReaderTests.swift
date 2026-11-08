import CloudKit
import Foundation
import Testing
import FastTabReader
import FastTabSync
@testable import FastTabWebReader
import IndieSharing

/// In-memory server for the web reader calls.
final class FakeWebReaderAPI: WebReaderAPI, @unchecked Sendable {
    var snapshots: [(version: Int, blob: WebSealedBlob)] = []
    var articles: [String: WebSealedBlob] = [:]
    var deletedArticles: [String] = []
    var inbox: [WebInboxItem] = []
    var acked: [String] = []
    var snapshotDeleted = false
    var webDevices: [WebReaderDevice] = []
    var calls: [String] = []
    var offline = false
    var onCall: ((String) -> Void)?
    struct Offline: Error {}

    func devices() async throws -> [WebReaderDevice] { if offline { throw Offline() }; return webDevices }
    func removeDevice(id: String) async throws {
        if offline { throw Offline() }
        calls.append("unpair:\(id)"); onCall?("unpair"); webDevices.removeAll { $0.id == id }
    }
    func approvePairing(id: String, code: String) async throws { calls.append("approve-id:\(id):\(code)") }
    func approvePairing(code: String) async throws { calls.append("approve-code:\(code)") }
    func putSnapshot(version: Int, blob: WebSealedBlob) async throws { snapshots.append((version, blob)) }
    func putArticle(id: String, blob: WebSealedBlob) async throws { articles[id] = blob }
    func deleteArticle(id: String) async throws { articles[id] = nil; deletedArticles.append(id) }
    func deleteSnapshot() async throws { if offline { throw Offline() }; calls.append("delete"); snapshotDeleted = true; onCall?("delete") }
    func pendingInbox(after cursor: String?) async throws -> WebInboxPage {
        if offline { throw Offline() }
        calls.append("poll")
        return WebInboxPage(items: inbox.filter { !acked.contains($0.id) }, cursor: nil)
    }
    func ackInbox(ids: [String]) async throws { calls.append("ack"); acked += ids }
}

@MainActor
final class RecordingSink: WebInboxSink {
    let mirror: ReaderMirror
    var progress: [(String, Double)] = []
    init(mirror: ReaderMirror) { self.mirror = mirror }
    func importHighlight(_ highlight: SyncedReaderHighlight) -> Bool {
        mirror.addOwn(highlight)
        return true
    }
    func applyProgress(url: String, fraction: Double, updatedAt: Date) { progress.append((url, fraction)) }
}

@Suite("Web reader")
struct WebReaderTests {
    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("webreader-\(UUID().uuidString)", isDirectory: true)
    }

    static let input = WebSnapshotInput(
        macName: "Test Mac",
        tabs: [
            .init(browserName: "Chrome", windowIndex: 1, tabIndex: 1, tabID: 11, url: "https://b.com", title: "B"),
            .init(browserName: "Chrome", windowIndex: 1, tabIndex: 0, tabID: 10, url: "https://a.com", title: "A"),
            .init(browserName: "Safari", windowIndex: 0, tabIndex: 0, url: "https://c.com", title: ""),
            .init(browserName: "Chrome", windowIndex: 1, tabIndex: 2, url: "chrome://settings", title: "Settings")
        ],
        bookmarks: [
            .init(id: "1", browserName: "Chrome", folderPath: "Bookmarks Bar/Reading", title: "Rust", url: "https://rust-lang.org"),
            .init(id: "2", browserName: "Chrome", title: "Top", url: "https://top.com")
        ],
        listItems: [
            SavedOnIPhoneLink(id: "l1", url: "https://read.me/x", title: "Unread", savedAt: Date(timeIntervalSince1970: 200)),
            {
                var read = SavedOnIPhoneLink(id: "l2", url: "https://done.me", title: "Read", savedAt: Date(timeIntervalSince1970: 100))
                read.readAt = Date()
                return read
            }(),
            {
                var trashed = SavedOnIPhoneLink(id: "l3", url: "https://gone.me", savedAt: Date())
                trashed.deletedAt = Date()
                return trashed
            }()
        ],
        articles: [
            .init(url: "https://read.me/x", title: "Unread", byline: "Ann", html: "<p>Hello <b>world</b></p>",
                  extractedAt: Date(timeIntervalSince1970: 300))
        ]
    )

    // MARK: Builder

    @Test("snapshot groups tabs per window in tab order and skips non-web URLs")
    func windows() throws {
        let build = WebSnapshotBuilder.build(Self.input, now: Date(timeIntervalSince1970: 0))
        let snapshot = build.snapshot
        #expect(snapshot.schema == "fasttab.web.snapshot/1")
        #expect(snapshot.macName == "Test Mac")
        #expect(snapshot.windows.map { $0.tabs.map(\.url) } == [["https://a.com", "https://b.com"], ["https://c.com"]])
        #expect(snapshot.windows[1].tabs[0].title == "https://c.com")
        #expect(snapshot.windows[0].tabs[0].id == "Chrome::1:10")
    }

    @Test("bookmarks become a folder tree per browser and folder path")
    func bookmarks() {
        let root = WebSnapshotBuilder.build(Self.input).snapshot.bookmarks
        let chrome = try! #require(root.children?.first)
        #expect(chrome.title == "Chrome")
        let bar = chrome.children?.first
        #expect(bar?.title == "Bookmarks Bar")
        #expect(bar?.children?.first?.title == "Reading")
        #expect(bar?.children?.first?.children?.first?.url == "https://rust-lang.org")
        #expect(chrome.children?.last?.url == "https://top.com")
    }

    @Test("lists: Up Next is unread live items, FastTab List all live; article ids linked")
    func lists() {
        let snapshot = WebSnapshotBuilder.build(Self.input).snapshot
        #expect(snapshot.lists.map(\.kind) == ["upNext", "list"])
        #expect(snapshot.lists[0].items.map(\.id) == ["l1"])
        #expect(snapshot.lists[1].items.map(\.id) == ["l1", "l2"])
        #expect(snapshot.lists[0].items[0].articleId == WebReaderJSON.articleID(for: "https://read.me/x"))
        #expect(snapshot.lists[1].items[1].articleId == nil)
    }

    @Test("articles: index carries hash/size of the separate body; bodies stay out of the snapshot")
    func articles() throws {
        let build = WebSnapshotBuilder.build(Self.input)
        let article = try #require(build.snapshot.articles.first)
        let body = try #require(build.articleBodies[article.id])
        #expect(article.contentHash == WebReaderJSON.sha256Hex(body))
        #expect(article.size == body.count)
        let decoded = try JSONDecoder().decode(WebArticleBody.self, from: body)
        #expect(decoded.schema == "fasttab.web.article/1")
        #expect(decoded.textLength == "Hello world".count)
        let snapshotJSON = String(decoding: try WebReaderJSON.encoder.encode(build.snapshot), as: UTF8.self)
        #expect(!snapshotJSON.contains("Hello"))
    }

    @Test("articles capped at 500 newest; oversize bodies dropped")
    func articleCap() {
        var input = Self.input
        input.articles = (0..<510).map {
            .init(url: "https://x.com/\($0)", title: "\($0)", byline: nil, html: "<p>x</p>",
                  extractedAt: Date(timeIntervalSince1970: Double($0)))
        } + [.init(url: "https://huge.com", title: "Huge", byline: nil,
                   html: String(repeating: "a", count: 2 * 1024 * 1024 + 1), extractedAt: Date(timeIntervalSince1970: 9999))]
        let build = WebSnapshotBuilder.build(input)
        #expect(build.snapshot.articles.count == 500)
        #expect(!build.snapshot.articles.contains { $0.url == "https://huge.com" })
        #expect(build.snapshot.articles.first?.url == "https://x.com/509")
        #expect(!build.snapshot.articles.contains { $0.url == "https://x.com/9" })
    }

    @Test("GET /v1/me/devices decodes the server's real shape (deviceID)")
    func decodesServerDevices() throws {
        // Captured from local theindie-api `feat/web-reader` (e2e run 2026-11-07).
        let json = #"{"devices":[{"deviceID":"770444e8-44b1-434f-9548-f5e2d14e61c1","publicKey":"wac2U-gJyhNWLEhHAFQ3ncvHKNZpgaIpKFbyZ1aC2mc","app":"fasttab","platform":"web","name":"Web browser","createdAt":1794067631124,"lastSeenAt":1794067631124}]}"#
        let devices = try LiveWebReaderAPI.decodeDevices(Data(json.utf8))
        #expect(devices.map(\.id) == ["770444e8-44b1-434f-9548-f5e2d14e61c1"])
        #expect(devices.first?.platform == "web")
    }

    @Test("articleId matches the browser's for fragment, query and trailing-slash URLs")
    func articleIDMatchesBrowser() {
        // Same vectors as theindieapp_website src/fasttab-web/test/crypto.test.ts.
        #expect(WebReaderJSON.articleID(for: "https://Example.com/a/b/?q=1&x=é#frag") == "d348c1f9023ae3eeae37d4ee26b821da")
        #expect(WebReaderJSON.articleID(for: "https://example.com/post?a=1#sec") == "a7e109ccedf1a8272e14cdcd58266c55")
        #expect(WebReaderJSON.articleID(for: "https://example.com") == "100680ad546ce6a577f42f52df33b4cf")
    }

    @Test("articleId = first 32 hex of SHA-256 of the URL without fragment")
    func articleID() {
        let id = WebReaderJSON.articleID(for: "https://example.com/a?b=1#frag")
        #expect(id == String(WebReaderJSON.sha256Hex(Data("https://example.com/a?b=1".utf8)).prefix(32)))
        #expect(id.count == 32)
    }

    // MARK: Crypto

    @Test("seal → open round trip for each recipient; wrong kind or device fails")
    func cryptoRoundTrip() throws {
        let a = DeviceKeyPair(), b = DeviceKeyPair()
        let idA = UUID().uuidString, idB = UUID().uuidString
        let blob = try WebReaderCrypto.seal(Data("hi".utf8), kind: .snapshot, for: [
            .init(deviceID: idA, publicKey: a.publicKey), .init(deviceID: idB, publicKey: b.publicKey)
        ])
        #expect(blob.suite == "hpke-x25519-sha256-chachapoly")
        #expect(try WebReaderCrypto.open(blob, kind: .snapshot, deviceID: idA, keyPair: a) == Data("hi".utf8))
        #expect(try WebReaderCrypto.open(blob, kind: .snapshot, deviceID: idB, keyPair: b) == Data("hi".utf8))
        #expect(throws: WebReaderCrypto.Failure.self) {
            try WebReaderCrypto.open(blob, kind: .article(id: "x"), deviceID: idA, keyPair: a)
        }
        #expect(throws: WebReaderCrypto.Failure.self) {
            try WebReaderCrypto.open(blob, kind: .snapshot, deviceID: idA, keyPair: b)
        }
    }

    /// theindieapp_website `src/fasttab-web/test/vectors/js-sealed.json` (branch
    /// feat/fasttab-web-reader): sealed by the browser's crypto.ts. Proves Mac and web agree.
    @Test("opens the browser-sealed vector")
    func jsVector() throws {
        let keyPair = try DeviceKeyPair(privateKeyRawRepresentation: Base64URL.decode("HZh8C91ZZi9dz1SWzvpxQZRcs3SlsMibF-LbT0oNs-o"))
        let blob = WebSealedBlob(
            suite: "hpke-x25519-sha256-chachapoly",
            wraps: [WebKeyWrap(deviceId: "3f0e9d1c-1111-4222-8333-944455556666",
                               enc: "4PRorIXcVoyMh6dfNwCci-UA5O1ApLviQDWM-f2nSiU",
                               wrappedKey: "PNcJK3UrTmHR8MftV1ugPncTxtJv6XTD_xbFY8XJcY0Zk_Nf2K0P3bLbCmR4N2_v")],
            ciphertext: try Base64URL.decode("JRjfVBarXFJtcLzInzRWkvgsvXV095Mysd8LOi40DKCFjj4R-y9xeDB0wiHJ1U0p7jdxvgmB3tjnyxD-nkO2FzvP9awGM8WrXw9PmfVQKs5t5CzYwhpt35UZoSflcZGf_m2_pRmr"))
        let plaintext = try WebReaderCrypto.open(blob, kind: .highlight(id: "abc"),
                                                 deviceID: "3f0e9d1c-1111-4222-8333-944455556666", keyPair: keyPair)
        #expect(String(decoding: plaintext, as: UTF8.self)
                == #"{"schema":"fasttab.web.highlight/1","quote":"JS → Swift","color":"pink"}"#)
    }

    // MARK: Uploader

    @Test("uploader sends changed articles only, deletes evicted ones, version goes up")
    @MainActor
    func uploader() async throws {
        let api = FakeWebReaderAPI()
        let web = DeviceKeyPair()
        let webID = UUID().uuidString.lowercased()
        let uploader = WebSnapshotUploader(api: api, ledgerURL: Self.tempDir().appendingPathComponent("ledger.json"),
                                           now: { Date(timeIntervalSince1970: 1) })
        let recipients = [WebReaderCrypto.Recipient(deviceID: webID, publicKey: web.publicKey)]
        #expect(try await uploader.upload(WebSnapshotBuilder.build(Self.input), to: []) == nil)

        let first = try #require(try await uploader.upload(WebSnapshotBuilder.build(Self.input), to: recipients))
        #expect(first.articlesUploaded == 1)
        let snapshot = try #require(api.snapshots.last)
        let opened = try WebReaderCrypto.open(snapshot.blob, kind: .snapshot, deviceID: webID, keyPair: web)
        #expect(try JSONDecoder().decode(WebSnapshot.self, from: opened).macName == "Test Mac")
        let articleID = WebReaderJSON.articleID(for: "https://read.me/x")
        _ = try WebReaderCrypto.open(try #require(api.articles[articleID]), kind: .article(id: articleID), deviceID: webID, keyPair: web)

        let second = try #require(try await uploader.upload(WebSnapshotBuilder.build(Self.input), to: recipients))
        #expect(second.articlesUploaded == 0)
        #expect(second.version > first.version)

        var noArticles = Self.input
        noArticles.articles = []
        let third = try #require(try await uploader.upload(WebSnapshotBuilder.build(noArticles), to: recipients))
        #expect(third.articlesDeleted == 1)
        #expect(api.deletedArticles == [articleID])
    }

    // MARK: Inbox

    @Test("inbox: highlight imported into the mirror as own (sent to CloudKit), progress applied, all acked")
    @MainActor
    func inboxImport() async throws {
        let mac = DeviceKeyPair()
        let macID = UUID().uuidString.lowercased()
        let api = FakeWebReaderAPI()
        func item(_ id: String, _ json: String) throws -> WebInboxItem {
            let blob = try WebReaderCrypto.seal(Data(json.utf8), kind: .highlight(id: id),
                                                for: [.init(deviceID: macID, publicKey: mac.publicKey)])
            return WebInboxItem(id: id, articleId: "a", suite: blob.suite, wraps: blob.wraps,
                                ciphertext: Base64URL.encode(blob.ciphertext))
        }
        let hid = UUID().uuidString
        api.inbox = [
            try item(hid, #"{"schema":"fasttab.web.highlight/1","url":"https://Read.me/x?utm_source=t","quote":"world","prefix":"Hello ","suffix":"!","color":"green","createdAt":"2026-11-07T10:00:00Z"}"#),
            try item("p1", #"{"schema":"fasttab.web.progress/1","url":"https://read.me/x","fraction":0.5,"updatedAt":"2026-11-07T10:00:00Z"}"#),
            WebInboxItem(id: "junk", articleId: "a", suite: "hpke-x25519-sha256-chachapoly", wraps: [], ciphertext: "AAAA")
        ]
        let support = Self.tempDir()
        let bridge = ReaderMirror.makeBridge(supportDirectory: support)
        let mirror = try #require(bridge.highlights as? ReaderMirror)
        let sink = RecordingSink(mirror: mirror)

        let summary = try await WebInboxImporter.run(api: api, deviceID: macID, keyPair: mac, sink: sink)
        #expect(summary == .init(highlights: 1, progress: 1, skipped: 1))
        #expect(Set(api.acked) == [hid, "p1", "junk"])
        #expect(sink.progress.first?.1 == 0.5)

        let info = try JSONDecoder().decode(ReaderHighlightInfo.self, from: try #require(mirror.syncedHighlights().first).payload)
        #expect(info.selectedText == "world")
        #expect(info.color == "green")
        #expect(info.urlKey == "https://read.me/x")
        #expect(info.urlString == "https://Read.me/x?utm_source=t")

        // The Mac now sends this one highlight (and only its own) to CloudKit.
        let pending = await bridge.pendingChanges()
        #expect(pending.saves.map(\.recordID.recordName) == [SyncedReaderHighlight(id: hid, urlKey: "", payload: Data()).recordName])
        // Re-running imports nothing new.
        #expect(try await WebInboxImporter.run(api: api, deviceID: macID, keyPair: mac, sink: sink).highlights == 0)
    }

    @Test("Mac bridge still never sends the phone's highlights")
    @MainActor
    func phoneHighlightsNotSent() async throws {
        let bridge = ReaderMirror.makeBridge(supportDirectory: Self.tempDir())
        let mirror = try #require(bridge.highlights as? ReaderMirror)
        _ = mirror.applyRemote(SyncedReaderHighlight(id: "phone", urlKey: "https://x.com", payload: Data("{}".utf8)))
        let pending = await bridge.pendingChanges()
        #expect(pending.saves.isEmpty)
        #expect(pending.deletes.isEmpty)
    }

    // MARK: Toggle-off cleanup

    static func freshDefaults() -> UserDefaults {
        let name = "webreader-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("cleanup: final poll + ack, then unpair web devices, then delete snapshot; flag cleared")
    @MainActor
    func cleanupOrder() async throws {
        let mac = DeviceKeyPair()
        let macID = UUID().uuidString.lowercased()
        let api = FakeWebReaderAPI()
        let blob = try WebReaderCrypto.seal(Data(#"{"schema":"fasttab.web.progress/1","url":"https://read.me/x","fraction":0.5,"updatedAt":"2026-11-07T10:00:00Z"}"#.utf8),
                                            kind: .highlight(id: "p1"), for: [.init(deviceID: macID, publicKey: mac.publicKey)])
        api.inbox = [WebInboxItem(id: "p1", articleId: "a", suite: blob.suite, wraps: blob.wraps, ciphertext: Base64URL.encode(blob.ciphertext))]
        api.webDevices = [WebReaderDevice(id: "w1", platform: "web", app: "fasttab", publicKey: "k"),
                          WebReaderDevice(id: "m1", platform: "macos", app: "fasttab", publicKey: "k"),
                          WebReaderDevice(id: "o1", platform: "web", app: "parklet", publicKey: "k")]
        let sink = RecordingSink(mirror: try #require(ReaderMirror.makeBridge(supportDirectory: Self.tempDir()).highlights as? ReaderMirror))
        let cleanup = WebReaderCleanup(defaults: Self.freshDefaults())
        cleanup.markPending()
        let ok = await cleanup.runIfPending(api: api) {
            _ = try await WebInboxImporter.run(api: api, deviceID: macID, keyPair: mac, sink: sink)
        }
        #expect(ok)
        #expect(Array(api.calls.prefix(2)) == ["poll", "ack"])
        let tail = api.calls.drop { $0 == "poll" || $0 == "ack" }
        #expect(Array(tail) == ["unpair:w1", "delete"])
        #expect(api.acked == ["p1"])
        #expect(api.webDevices.map(\.id) == ["m1", "o1"])
        #expect(!cleanup.isPending)
    }

    @Test("cleanup offline: nothing deleted, flag persists, retry at launch succeeds and clears it")
    @MainActor
    func cleanupOfflineRetry() async throws {
        let api = FakeWebReaderAPI()
        api.offline = true
        api.webDevices = [WebReaderDevice(id: "w1", platform: "web", app: "fasttab", publicKey: "k")]
        let defaults = Self.freshDefaults()
        let cleanup = WebReaderCleanup(defaults: defaults)
        cleanup.markPending()
        let first = await cleanup.runIfPending(api: api) { _ = try await api.pendingInbox(after: nil) }
        #expect(!first)
        #expect(!api.snapshotDeleted)
        #expect(api.webDevices.count == 1)
        // App relaunch: new instance reads the persisted flag.
        api.offline = false
        let relaunched = WebReaderCleanup(defaults: defaults)
        #expect(relaunched.isPending)
        #expect(await relaunched.runIfPending(api: api) { _ = try await api.pendingInbox(after: nil) })
        #expect(api.snapshotDeleted)
        #expect(api.webDevices.isEmpty)
        #expect(!WebReaderCleanup(defaults: defaults).isPending)
    }

    @Test("re-enabling clears the pending flag without deleting anything")
    @MainActor
    func cleanupCancelledByReenable() async {
        let api = FakeWebReaderAPI()
        api.webDevices = [WebReaderDevice(id: "w1", platform: "web", app: "fasttab", publicKey: "k")]
        let cleanup = WebReaderCleanup(defaults: Self.freshDefaults())
        cleanup.markPending()
        cleanup.cancel()
        #expect(await cleanup.runIfPending(api: api) { _ = try await api.pendingInbox(after: nil) })
        #expect(api.calls.isEmpty)
        #expect(!api.snapshotDeleted)
        #expect(api.webDevices.count == 1)
    }

    @Test("re-enabled while the delete is in flight: outcome says the server was touched (uploader must reset)")
    @MainActor
    func cleanupInterruptedAfterDelete() async {
        let api = FakeWebReaderAPI()
        let defaults = Self.freshDefaults()
        let cleanup = WebReaderCleanup(defaults: defaults)
        api.onCall = { if $0 == "delete" { defaults.removeObject(forKey: WebReaderCleanup.pendingDefaultsKey) } }
        cleanup.markPending()
        let outcome = await cleanup.run(api: api) { _ = try await api.pendingInbox(after: nil) }
        #expect(outcome == .interrupted(touchedServer: true))
        #expect(!cleanup.isPending)
    }

    @Test("re-enabled before anything was removed: interrupted, server untouched")
    @MainActor
    func cleanupInterruptedBeforeTouch() async {
        let api = FakeWebReaderAPI()
        api.webDevices = [WebReaderDevice(id: "w1", platform: "web", app: "fasttab", publicKey: "k")]
        let cleanup = WebReaderCleanup(defaults: Self.freshDefaults())
        cleanup.markPending()
        let outcome = await cleanup.run(api: api) { cleanup.cancel() }
        #expect(outcome == .interrupted(touchedServer: false))
        #expect(api.webDevices.count == 1)
        #expect(!api.snapshotDeleted)
    }

    @Test("off -> on -> off mid-run: run notices the flag is back and finishes")
    @MainActor
    func cleanupOffOnOff() async {
        let api = FakeWebReaderAPI()
        api.webDevices = [WebReaderDevice(id: "w1", platform: "web", app: "fasttab", publicKey: "k")]
        let cleanup = WebReaderCleanup(defaults: Self.freshDefaults())
        cleanup.markPending()
        let outcome = await cleanup.run(api: api) { cleanup.cancel(); cleanup.markPending() }
        #expect(outcome == .clean)
        #expect(api.snapshotDeleted)
    }
}


@Suite("Web reader pairing input (v1.3 code only)")
struct WebPairingInputTests {
    @Test func typedCodeIsNormalized() {
        #expect(WebPairingRequest(input: " abcd-efgh ") == .code("ABCDEFGH"))
        #expect(WebPairingRequest(input: "ab cd ef gh") == .code("ABCDEFGH"))
    }

    @Test func pastedLegacyLinkStillWorks() {
        #expect(WebPairingRequest(input: "fasttab://pair-web?id=abc-123&code=wxyz2345") == .link(id: "abc-123", code: "WXYZ2345"))
    }

    @Test func rejectsWrongLengthOrEmpty() {
        #expect(WebPairingRequest(input: "") == nil)
        #expect(WebPairingRequest(input: "ABC") == nil)
        #expect(WebPairingRequest(input: "fasttab://pair-web?code=ABCDEFGH") == nil)
    }

    @Test func codeGoesToCodeOnlyRouteAndLinkToLegacyRoute() async throws {
        let api = FakeWebReaderAPI()
        try await WebPairingRequest.code("ABCDEFGH").approve(with: api)
        try await WebPairingRequest.link(id: "p1", code: "WXYZ2345").approve(with: api)
        #expect(api.calls == ["approve-code:ABCDEFGH", "approve-id:p1:WXYZ2345"])
    }
}
