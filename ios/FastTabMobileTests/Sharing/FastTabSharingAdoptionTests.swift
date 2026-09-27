import FastTabSync
import IndieAccount
import IndieLibKit
import IndieShareSync
import IndieSharing
import XCTest
@testable import FastTabMobile

/// The admission test of the L1 sharing move: Fast Tab adopts `IndieAccount` +
/// `IndieShareSync` through its three adapters only. Two phones (Sam sends, Alex receives)
/// sign in against one fake server; Sam shares a tab, Alex's sync stores it, and a comment
/// from each side lands in their one thread.
@MainActor
final class FastTabSharingAdoptionTests: XCTestCase {
    private let sam = TwoPhoneShareServer.Person(userID: UUID(), displayName: "Sam")
    private let alex = TwoPhoneShareServer.Person(userID: UUID(), displayName: "Alex")
    private var stubServer: StubAccountServer!
    private var phones: [Phone] = []

    /// One install of Fast Tab: its own keychain, defaults, library and sharing services.
    private struct Phone {
        let person: TwoPhoneShareServer.Person
        let session: AccountSession
        let library: FastTabLibraryWriter
        let sharing: FastTabSharing
        let defaultsSuiteName: String
    }

    override func setUp() async throws {
        stubServer = StubAccountServer()
        _ = TwoPhoneShareServer(on: stubServer, appSlug: IndieAccountConfiguration.fastTab.appSlug, people: [sam, alex])
    }

    override func tearDown() async throws {
        for phone in phones { UserDefaults.standard.removePersistentDomain(forName: phone.defaultsSuiteName) }
        phones = []
        stubServer = nil
    }

    private func signedInPhone(_ person: TwoPhoneShareServer.Person) async throws -> Phone {
        let keychain = InMemoryKeychain()
        let suiteName = "fasttab-sharing-tests.\(person.displayName)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let session = AccountSession(
            apiClient: stubServer.makeClient(sessionToken: nil, keychain: keychain), keychain: keychain,
            appSlug: IndieAccountConfiguration.fastTab.appSlug, userDefaults: defaults)
        let library = FastTabLibraryWriter(database: try LibraryDatabase.inMemory())
        let sharing = FastTabSharing(accountSession: session, library: library, userDefaults: defaults)

        let signedIn = await session.signIn(
            identityToken: person.identityToken, authorizationCode: nil, rawNonce: "nonce", fullName: nil)
        XCTAssertTrue(signedIn, "\(person.displayName) signs in")
        XCTAssertEqual(session.deviceStatus.isRegistered, true, "\(person.displayName)'s phone registers")
        await sharing.accountChanged(signedInUserID: session.profile?.userID)
        await sharing.coordinator.refreshAll()

        let phone = Phone(person: person, session: session, library: library, sharing: sharing, defaultsSuiteName: suiteName)
        phones.append(phone)
        return phone
    }

    private func profile(of person: TwoPhoneShareServer.Person) -> Profile {
        Profile(userID: person.userID, displayName: person.displayName)
    }

    func testATabSharedFromOnePhoneArrivesOnTheOtherAndCommentsReachTheirThread() async throws {
        let samPhone = try await signedInPhone(sam)
        let alexPhone = try await signedInPhone(alex)

        // Sam shares a tab from the Mac.
        let tab = SyncedTab(
            id: "tab-1", deviceID: "mac", browserName: "Safari", title: "Swift Testing",
            url: "https://swift.org/testing")
        let link = try await samPhone.library.saveForSharing(tab)
        let outcome = await samPhone.sharing.coordinator.send(link.id, to: [profile(of: alex)])
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.sentToNames, ["Alex"])

        // Alex syncs: the link is on his phone, from Sam.
        await alexPhone.sharing.coordinator.syncReceivedNotes()
        XCTAssertNil(alexPhone.sharing.coordinator.receivedNotesSync.lastError)
        let received = try await alexPhone.library.store.timeline(TimelineQuery(authorship: .received), limit: 10).entries
        XCTAssertEqual(received.count, 1)
        let receivedItem = try XCTUnwrap(received.first?.item)
        XCTAssertEqual(receivedItem.body, "Swift Testing\nhttps://swift.org/testing")
        XCTAssertEqual(receivedItem.source, .fastTabReceived)
        let receivedShare = try await alexPhone.library.store.receivedShare(of: receivedItem.id)
        XCTAssertEqual(receivedShare?.senderUserID.uuid, sam.userID)
        XCTAssertEqual(receivedShare?.senderName, "Sam")
        let shareID = try XCTUnwrap(receivedShare?.shareID)

        // Alex comments; Sam's sync puts it in the thread with Alex on the shared link.
        try await alexPhone.sharing.coordinator.commentSender.send("Great read", onShare: shareID)
        await samPhone.sharing.coordinator.syncReceivedNotes()
        let samThreads = try await samPhone.library.store.commentThreads(of: link.id)
        XCTAssertEqual(samThreads.count, 1)
        let samThread = try XCTUnwrap(samThreads.first)
        XCTAssertEqual(samThread.conversation.otherUserID?.uuid, alex.userID)
        XCTAssertEqual(samThread.comments.map(\.body), ["Great read"])
        XCTAssertEqual(samThread.comments.first?.isMine, false)

        // Sam replies in that thread; Alex's sync adds it to the same one.
        try await samPhone.sharing.coordinator.commentSender.send(
            "Glad you liked it", onShare: shareID, toRecipient: AuthorID(alex.userID))
        await alexPhone.sharing.coordinator.syncReceivedNotes()
        let alexThreads = try await alexPhone.library.store.commentThreads(of: receivedItem.id)
        XCTAssertEqual(alexThreads.count, 1)
        XCTAssertEqual(alexThreads.first?.comments.map(\.body), ["Great read", "Glad you liked it"])
        XCTAssertEqual(alexThreads.first?.comments.map(\.isMine), [true, false])
        XCTAssertEqual(alexThreads.first?.comments.map(\.status), [.sent, .sent])
    }

    func testFastTabSignsInAsItsOwnApp() {
        XCTAssertEqual(IndieAccountConfiguration.fastTab.appSlug, "fasttab")
        XCTAssertNotEqual(IndieAccountConfiguration.fastTab.keychainService, "app.theindie.account",
                          "each app signs in separately: Parklet's keychain service is not shared")
        XCTAssertEqual(IndieShareSyncConfiguration.fastTab.userDefaultsKeyPrefix, "fasttab.")
    }
}

private extension AccountSession.DeviceStatus {
    var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}
