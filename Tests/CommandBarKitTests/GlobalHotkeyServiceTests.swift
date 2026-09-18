import AppKit
import Carbon.HIToolbox
import Testing
@testable import CommandBarKit

/// FastTab's registered hotkeys carry 'CBAR'; the packed value must not drift.
@Test func fourCharCodePacksAsciiBigEndian() {
    #expect(GlobalHotkeyService.fourCharCode("CBAR") == 0x43424152)
}

@Test func carbonModifiersMapEachDeviceIndependentFlag() {
    #expect(GlobalHotkeyService.carbonModifiers(from: []) == 0)
    #expect(GlobalHotkeyService.carbonModifiers(from: .command) == UInt32(cmdKey))
    #expect(GlobalHotkeyService.carbonModifiers(from: .option) == UInt32(optionKey))
    #expect(GlobalHotkeyService.carbonModifiers(from: .control) == UInt32(controlKey))
    #expect(GlobalHotkeyService.carbonModifiers(from: .shift) == UInt32(shiftKey))
    #expect(
        GlobalHotkeyService.carbonModifiers(from: [.command, .shift])
            == UInt32(cmdKey) | UInt32(shiftKey)
    )
}

@Test func carbonModifiersIgnoreNonHotkeyFlags() {
    #expect(GlobalHotkeyService.carbonModifiers(from: [.command, .capsLock, .function]) == UInt32(cmdKey))
}

@Test func registrationResultMessageNamesHostApp() {
    #expect(HotkeyRegistrationResult(status: noErr).userMessage(appName: "FastTab") == nil)
    #expect(
        HotkeyRegistrationResult(status: OSStatus(eventHotKeyExistsErr)).userMessage(appName: "FastTab")
            == "Shortcut already registered by FastTab or another app."
    )
}
