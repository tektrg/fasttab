import AppKit
import Carbon.HIToolbox
import OSLog

public struct HotkeyRegistrationResult: Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var isSuccess: Bool { status == noErr }

    /// Plain-English failure reason, or nil on success. `appName` names the
    /// host app in the "already registered" message.
    public func userMessage(appName: String) -> String? {
        guard status != noErr else { return nil }

        switch status {
        case OSStatus(eventHotKeyExistsErr):
            return "Shortcut already registered by \(appName) or another app."
        default:
            return "Shortcut is unavailable. It may be reserved by macOS or another app. (OSStatus \(status))"
        }
    }
}

/// System-wide hotkeys via Carbon `RegisterEventHotKey`. Each app passes its own
/// four-char `signature` (only events carrying it are delivered) and log identity.
@MainActor
public final class GlobalHotkeyService {
    public var onHotKeyPressed: (@MainActor @Sendable (UInt32) -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]
    private let signature: OSType
    private let logger: Logger

    public init(signature: OSType, logSubsystem: String, logCategory: String) {
        self.signature = signature
        self.logger = Logger(subsystem: logSubsystem, category: logCategory)
    }

    isolated deinit {
        unregisterAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// Packs a four-character ASCII code (e.g. "CBAR") into an `OSType`.
    public nonisolated static func fourCharCode(_ code: String) -> OSType {
        precondition(code.utf8.count == 4, "four-char code must be 4 ASCII bytes")
        return code.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    @discardableResult
    public func registerShortcut(id: UInt32 = 1, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotkeyRegistrationResult {
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
            logger.error("Failed to register global hotkey id=\(id). status=\(status)")
            return HotkeyRegistrationResult(status: status)
        }

        registeredHotKeys[id] = registeredRef
        logger.info("Registered global hotkey id=\(id). keyCode=\(Int(keyCode)) modifiers=\(modifiers.rawValue)")
        return HotkeyRegistrationResult(status: status)
    }

    public func unregisterShortcut(id: UInt32 = 1) {
        guard let ref = registeredHotKeys.removeValue(forKey: id) else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr {
            logger.error("Failed to unregister global hotkey id=\(id). status=\(status)")
        }
    }

    public func unregisterAll() {
        for (id, ref) in registeredHotKeys {
            let status = UnregisterEventHotKey(ref)
            if status != noErr {
                logger.error("Failed to unregister global hotkey id=\(id). status=\(status)")
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

                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated {
                    let service = Unmanaged<GlobalHotkeyService>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    service.handleHotKeyPressed(eventRef)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            logger.error("Failed to install Carbon hotkey event handler. status=\(status)")
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
            logger.error("Failed to extract hotkey id from event. status=\(status)")
            return
        }

        guard incomingHotKeyID.signature == signature else {
            return
        }

        onHotKeyPressed?(incomingHotKeyID.id)
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0

        if masked.contains(.command) { result |= UInt32(cmdKey) }
        if masked.contains(.option)  { result |= UInt32(optionKey) }
        if masked.contains(.control) { result |= UInt32(controlKey) }
        if masked.contains(.shift)   { result |= UInt32(shiftKey) }

        return result
    }
}
