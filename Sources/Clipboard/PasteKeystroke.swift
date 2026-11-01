// PasteKeystroke.swift
//
// Sends ⌘V to the frontmost app, so picking an item in the clipboard history
// pastes it. Posting keystrokes into other apps needs the Accessibility
// permission; without it, macOS drops the events silently, so callers check
// `isAllowed` first and fall back to leaving the item on the clipboard.

import Carbon.HIToolbox
import Cocoa

@MainActor
enum PasteKeystroke {
    /// Whether this process may post keystrokes to other apps.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    private static var didAskThisLaunch = false

    /// Shows the system prompt that leads to System Settings > Privacy &
    /// Security > Accessibility, once per launch so a user who declined isn't
    /// nagged on every pick.
    static func requestPermission() {
        guard !didAskThisLaunch else { return }
        didAskThisLaunch = true
        // The value of kAXTrustedCheckOptionPrompt, spelled out because the
        // imported global is a mutable C variable Swift 6 won't read here.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Posts ⌘V key down and up.
    static func post() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding (⌘ after ⌘1 to ⌘9) shouldn't mix
        // into the synthetic keystroke.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let key = keyCode(typing: "v") ?? CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types `character` in the current keyboard layout, so ⌘V
    /// lands on "V" in layouts like Dvorak where it isn't the ANSI V key.
    private static func keyCode(typing character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = Array(String(character).utf16)

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
                if status == noErr, Array(chars.prefix(length)) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
