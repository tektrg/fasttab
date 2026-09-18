import Testing
@testable import AgentBar

struct AgentBarIdentityTests {
    @Test func bundleIdentifierIsDistinctFromFastTab() {
        #expect(AgentBarIdentity.bundleIdentifier == "com.trungluong.AgentBar")
    }
}
