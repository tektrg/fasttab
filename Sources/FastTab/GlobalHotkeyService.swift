import AppKit
import Carbon.HIToolbox
import OSLog

private let hotkeyLogger = Logger(subsystem: "com.trungluong.FastTab", category: "GlobalHotkey")

struct HotkeyRegistrationResult {
    let status: OSStatus

    var isSuccess: Bool { status == noErr }

    var userMessage: String? {
        guard status != noErr else { return nil }

        switch status {
        case OSStatus(eventHotKeyExistsErr):
            return "Shortcut already registered by FastTab or another app."
        default:
            return "Shortcut is unavailable. It may be reserved by macOS or another app. (OSStatus \(status))"
        }
    }
}

final class GlobalHotkeyService {
    var onHotKeyPressed: ((UInt32) -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]
    private let signature: OSType = 0x43424152 // 'CBAR'

    deinit {
        unregisterAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func registerShortcut(id: UInt32 = 1, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyRegistrationResult {
        installEventHandlerIfNeeded()
        unregisterShortcut(id: id)

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var registeredRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredRef
        )

        guard status == noErr, let registeredRef else {
            hotkeyLogger.error("Failed to register global hotkey id=\(id). status=\(status)")
            return HotkeyRegistrationResult(status: status)
        }

        registeredHotKeys[id] = registeredRef
        hotkeyLogger.info("Registered global hotkey id=\(id). keyCode=\(Int(keyCode)) modifiers=\(modifiers.rawValue)")
        return HotkeyRegistrationResult(status: status)
    }

    func unregisterShortcut(id: UInt32 = 1) {
        guard let ref = registeredHotKeys.removeValue(forKey: id) else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr {
            hotkeyLogger.error("Failed to unregister global hotkey id=\(id). status=\(status)")
        }
    }

    func unregisterAll() {
        for (id, ref) in registeredHotKeys {
            let status = UnregisterEventHotKey(ref)
            if status != noErr {
                hotkeyLogger.error("Failed to unregister global hotkey id=\(id). status=\(status)")
            }
        }
        registeredHotKeys.removeAll()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }

                let service = Unmanaged<GlobalHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                service.handleHotKeyPressed(eventRef)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            hotkeyLogger.error("Failed to install Carbon hotkey event handler. status=\(status)")
        }
    }

    private func handleHotKeyPressed(_ eventRef: EventRef) {
        var incomingHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &incomingHotKeyID
        )

        guard status == noErr else {
            hotkeyLogger.error("Failed to extract hotkey id from event. status=\(status)")
            return
        }

        guard incomingHotKeyID.signature == signature else {
            return
        }

        onHotKeyPressed?(incomingHotKeyID.id)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0

        if masked.contains(.command) { result |= UInt32(cmdKey) }
        if masked.contains(.option)  { result |= UInt32(optionKey) }
        if masked.contains(.control) { result |= UInt32(controlKey) }
        if masked.contains(.shift)   { result |= UInt32(shiftKey) }

        return result
    }
}
