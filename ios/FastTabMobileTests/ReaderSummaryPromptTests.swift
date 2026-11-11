import XCTest
@testable import FastTabMobile

// MARK: - Normalising what the person typed

final class ReaderSummaryPromptTests: XCTestCase {
    func testBlankOrWhitespaceMeansDefault() {
        XCTAssertNil(ReaderSummaryPrompt.normalized(""))
        XCTAssertNil(ReaderSummaryPrompt.normalized("  \n\t "))
    }

    func testTheDefaultTextItselfCountsAsDefaultSoServerImprovementsStillFlowIn() {
        XCTAssertNil(ReaderSummaryPrompt.normalized(ReaderSummaryPrompt.defaultInstruction))
        XCTAssertNil(ReaderSummaryPrompt.normalized("\n" + ReaderSummaryPrompt.defaultInstruction + "  \n"))
    }

    func testCustomTextIsTrimmedAndKept() {
        XCTAssertEqual(ReaderSummaryPrompt.normalized("  Three bullets only.  \n"), "Three bullets only.")
        XCTAssertEqual(ReaderSummaryPrompt.normalized(ReaderSummaryPrompt.defaultInstruction + " Be brief."),
                       ReaderSummaryPrompt.defaultInstruction + " Be brief.")
    }

    func testTheDefaultMirrorsTheServerAndFitsItsOwnLimit() {
        XCTAssertTrue(ReaderSummaryPrompt.defaultInstruction.hasPrefix("Summarize the article below for a busy reader."))
        XCTAssertTrue(ReaderSummaryPrompt.defaultInstruction.contains("**Gist:**"))
        XCTAssertLessThanOrEqual(ReaderSummaryPrompt.defaultInstruction.utf16.count, ReaderSummaryPrompt.maxInstructionLength)
    }

    func testLimitCountsUTF16UnitsLikeTheServer() {
        let atLimit = String(repeating: "a", count: ReaderSummaryPrompt.maxInstructionLength)
        XCTAssertFalse(ReaderSummaryPromptDraft(stored: atLimit).isOverLimit)
        XCTAssertTrue(ReaderSummaryPromptDraft(stored: atLimit + "a").isOverLimit)
        // 1,001 emoji = 1,001 Characters but 2,002 UTF-16 units: over the server's limit.
        XCTAssertTrue(ReaderSummaryPromptDraft(stored: String(repeating: "😀", count: 1_001)).isOverLimit)
    }
}

// MARK: - The editor's draft

final class ReaderSummaryPromptDraftTests: XCTestCase {
    func testStartsFromTheDefaultTextWhenNothingIsStored() {
        let draft = ReaderSummaryPromptDraft(stored: nil)
        XCTAssertEqual(draft.text, ReaderSummaryPrompt.defaultInstruction)
        XCTAssertTrue(draft.isUsingDefault)
        XCTAssertFalse(draft.canSave(stored: nil))
    }

    func testStartsFromTheStoredCustomText() {
        let draft = ReaderSummaryPromptDraft(stored: "Five bullets.")
        XCTAssertEqual(draft.text, "Five bullets.")
        XCTAssertFalse(draft.isUsingDefault)
        XCTAssertFalse(draft.canSave(stored: "Five bullets."))
    }

    func testEditingEnablesSaveAndRevertingDisablesIt() {
        var draft = ReaderSummaryPromptDraft(stored: nil)
        draft.text += " Be brief."
        XCTAssertTrue(draft.canSave(stored: nil))
        draft.text = ReaderSummaryPrompt.defaultInstruction
        XCTAssertFalse(draft.canSave(stored: nil))
    }

    func testBlankDraftSavesAsReturnToDefaultOnlyWhenSomethingCustomWasStored() {
        var draft = ReaderSummaryPromptDraft(stored: "Custom")
        draft.text = "   "
        XCTAssertTrue(draft.isUsingDefault)
        XCTAssertTrue(draft.canSave(stored: "Custom"))
        XCTAssertFalse(ReaderSummaryPromptDraft(stored: nil).canSave(stored: nil))
    }

    func testOverLimitCannotBeSaved() {
        var draft = ReaderSummaryPromptDraft(stored: nil)
        draft.text = String(repeating: "a", count: ReaderSummaryPrompt.maxInstructionLength + 1)
        XCTAssertTrue(draft.isOverLimit)
        XCTAssertFalse(draft.canSave(stored: nil))
    }

    func testResetGoesBackToTheDefaultText() {
        var draft = ReaderSummaryPromptDraft(stored: "Custom")
        draft.resetToDefault()
        XCTAssertEqual(draft.text, ReaderSummaryPrompt.defaultInstruction)
        XCTAssertTrue(draft.canSave(stored: "Custom")) // saving it clears the stored custom prompt
    }

    func testHostileTextIsJustText() {
        var draft = ReaderSummaryPromptDraft(stored: nil)
        draft.text = "$(echo INJECTED) {language}"
        XCTAssertEqual(draft.normalized, "$(echo INJECTED) {language}") // kept verbatim; the server fills {language}
    }
}

// MARK: - Store (UserDefaults + iCloud key-value store, last writer wins)

private final class FakeCloud: PromptCloudStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func promptData(forKey key: String) -> Data? { values[key] }
    func setPromptData(_ data: Data?, forKey key: String) { values[key] = data }
}

@MainActor
final class ReaderSummaryPromptStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000)

    override func setUp() { defaults = UserDefaults(suiteName: "ReaderSummaryPromptStoreTests-\(UUID())")! }

    private func store(cloud: PromptCloudStorage? = nil, defaults: UserDefaults? = nil) -> ReaderSummaryPromptStore {
        ReaderSummaryPromptStore(local: defaults ?? self.defaults, cloud: cloud, now: { [unowned self] in
            clock = clock.addingTimeInterval(10)
            return clock
        })
    }

    func testStartsOnTheDefault() {
        XCTAssertNil(store().customInstruction)
    }

    func testSavePersistsAcrossRelaunchAndNormalises() {
        let first = store()
        first.save(instruction: "  Five bullets.  ")
        XCTAssertEqual(first.customInstruction, "Five bullets.")
        XCTAssertEqual(store().customInstruction, "Five bullets.") // new instance, same defaults
    }

    func testSavingTheDefaultTextOrBlankClearsTheCustomPrompt() {
        let store = store()
        store.save(instruction: "Custom")
        store.save(instruction: ReaderSummaryPrompt.defaultInstruction)
        XCTAssertNil(store.customInstruction)
        store.save(instruction: "Custom")
        store.save(instruction: "  ")
        XCTAssertNil(store.customInstruction)
    }

    func testResetClearsAndStaysClearedAfterRelaunch() {
        let first = store()
        first.save(instruction: "Custom")
        first.reset()
        XCTAssertNil(first.customInstruction)
        XCTAssertNil(store().customInstruction)
    }

    func testOverLongTextIsRefusedAndNothingChanges() {
        let store = store()
        store.save(instruction: "Keep me")
        store.save(instruction: String(repeating: "a", count: ReaderSummaryPrompt.maxInstructionLength + 1))
        XCTAssertEqual(store.customInstruction, "Keep me")
    }

    func testSaveIsPushedToTheCloud() {
        let cloud = FakeCloud()
        store(cloud: cloud).save(instruction: "Custom")
        XCTAssertNotNil(cloud.values[ReaderSummaryPromptStore.cloudKey])
    }

    func testNewerCloudValueWinsOnLaunchAndOnChangeNotification() {
        let cloud = FakeCloud()
        let a = store(cloud: cloud)
        a.save(instruction: "From device A")

        // Device B: its own defaults, same cloud; launches with A's newer value.
        let otherDefaults = UserDefaults(suiteName: "ReaderSummaryPromptStoreTests-B-\(UUID())")!
        let b = store(cloud: cloud, defaults: otherDefaults)
        XCTAssertEqual(b.customInstruction, "From device A")

        b.save(instruction: "From device B") // newer than A's
        a.mergeFromCloud()
        XCTAssertEqual(a.customInstruction, "From device B")
    }

    func testOlderCloudValueDoesNotOverwriteALocalEdit() {
        let cloud = FakeCloud()
        let a = store(cloud: cloud)
        a.save(instruction: "Old")
        let stale = cloud.values[ReaderSummaryPromptStore.cloudKey]!
        a.save(instruction: "Newer local")
        cloud.values[ReaderSummaryPromptStore.cloudKey] = stale
        a.mergeFromCloud()
        XCTAssertEqual(a.customInstruction, "Newer local")
    }

    func testResetSyncsToTheOtherDeviceToo() {
        let cloud = FakeCloud()
        let a = store(cloud: cloud)
        a.save(instruction: "Custom")
        let b = store(cloud: cloud, defaults: UserDefaults(suiteName: "ReaderSummaryPromptStoreTests-B-\(UUID())")!)
        XCTAssertEqual(b.customInstruction, "Custom")
        a.reset()
        b.mergeFromCloud()
        XCTAssertNil(b.customInstruction)
    }

    func testGarbageInTheCloudOrDefaultsIsIgnored() {
        let cloud = FakeCloud()
        cloud.values[ReaderSummaryPromptStore.cloudKey] = Data("not json".utf8)
        defaults.set(Data("also not json".utf8), forKey: ReaderSummaryPromptStore.defaultsKey)
        let store = store(cloud: cloud)
        XCTAssertNil(store.customInstruction)
        store.mergeFromCloud()
        XCTAssertNil(store.customInstruction)
    }
}
