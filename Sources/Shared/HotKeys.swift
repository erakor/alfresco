// HotKeys.swift
//
// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no
// Accessibility or Input Monitoring permission.

import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkeys (Carbon)

/// Registers system-wide hotkeys. Carbon hotkeys are delivered through the
/// app's own event loop, so no privacy permission is involved.
final class HotKeyManager {
    typealias Action = @MainActor @Sendable () -> Void

    private static let signature = fourCharCode("LNCH")

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1

    deinit {
        for hotKeyRef in hotKeyRefs { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns false when macOS refuses the shortcut (usually because another
    /// app already registered it).
    func register(_ hotKey: HotKey, action: @escaping Action) -> Bool {
        guard installHandlerIfNeeded() else { return false }

        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == OSStatus(noErr), let hotKeyRef else { return false }

        hotKeyRefs.append(hotKeyRef)
        actions[id] = action
        return true
    }

    /// One Carbon handler serves every hotkey; it tells them apart by the
    /// EventHotKeyID each one was registered with.
    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == OSStatus(noErr) else { return status }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handlePress(hotKeyID)
                    ? OSStatus(noErr)
                    : OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        return status == OSStatus(noErr)
    }

    private func handlePress(_ hotKeyID: EventHotKeyID) -> Bool {
        guard hotKeyID.signature == Self.signature, let action = actions[hotKeyID.id] else {
            return false
        }
        Task { @MainActor in action() }
        return true
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
