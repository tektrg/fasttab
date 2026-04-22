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
            return "Shortcut already registered by FastTab."
        default:
            return "Shortcut is unavailable. It may be reserved by macOS or another app. (OSStatus \(status))"
        }
    }
}

final class GlobalHotkeyService {
    var onHotKeyPressed: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    private let hotKeyID = EventHotKeyID(
        signature: 0x43424152, // 'CBAR'
        id: 1
    )

    deinit {
        unregisterShortcut()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func registerShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyRegistrationResult {
        installEventHandlerIfNeeded()
        unregisterShortcut()

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
            hotkeyLogger.error("Failed to register global hotkey. status=\(status)")
            return HotkeyRegistrationResult(status: status)
        }

        hotKeyRef = registeredRef
        hotkeyLogger.info("Registered global hotkey. keyCode=\(Int(keyCode)) modifiers=\(modifiers.rawValue)")
        return HotkeyRegistrationResult(status: status)
    }

    private func unregisterShortcut() {
        guard let hotKeyRef else { return }
        let status = UnregisterEventHotKey(hotKeyRef)
        if status != noErr {
            hotkeyLogger.error("Failed to unregister previous global hotkey. status=\(status)")
        }
        self.hotKeyRef = nil
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

        guard incomingHotKeyID.signature == hotKeyID.signature,
              incomingHotKeyID.id == hotKeyID.id else {
            return
        }

        onHotKeyPressed?()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0

        if masked.contains(.command) { result |= UInt32(cmdKey) }
        if masked.contains(.option) { result |= UInt32(optionKey) }
        if masked.contains(.control) { result |= UInt32(controlKey) }
        if masked.contains(.shift) { result |= UInt32(shiftKey) }

        return result
    }
}
