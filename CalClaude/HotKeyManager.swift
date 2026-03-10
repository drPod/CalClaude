import AppKit
import Carbon
import Foundation

private func hotKeyCarbonHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.handleHotKey()
    }
    return noErr
}

/// Registers a global hotkey using the Carbon API and invokes a callback on the main thread.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCarbonHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4343_6C75) // "CClu"
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        assert(status == noErr, "RegisterEventHotKey failed: \(status)")
    }

    fileprivate func handleHotKey() {
        callback()
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }
}

enum CarbonModifiers {
    static func from(cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if cocoa.contains(.control) { carbon |= UInt32(controlKey) }
        if cocoa.contains(.command) { carbon |= UInt32(cmdKey) }
        if cocoa.contains(.shift) { carbon |= UInt32(shiftKey) }
        if cocoa.contains(.option) { carbon |= UInt32(optionKey) }
        if cocoa.contains(.capsLock) { carbon |= UInt32(alphaLock) }
        return carbon
    }
}
