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

    /// Where a pick should be pasted: the app that was in front, and the
    /// clipboard's change count right after the item was written to it.
    struct Target {
        let app: pid_t
        let changeCount: Int
    }

    /// The app in front, to paste into once the panel is gone (the panels
    /// don't activate the app, so it is where the user was working). nil
    /// without the Accessibility permission, which macOS is then asked for
    /// (once per launch), so the item is only left on the clipboard.
    static func target() -> Target? {
        guard isAllowed else {
            requestPermission()
            return nil
        }
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return Target(app: front, changeCount: NSPasteboard.general.changeCount)
    }

    /// Posts ⌘V to `target` once keyboard focus has settled, after a panel
    /// closed. Skipped if the user switched apps meanwhile, opened either
    /// panel (whose field would receive it), or copied something else, so
    /// only the picked item can be pasted. Cancel the task to drop it.
    static func paste(into target: Target) -> Task<Void, Never> {
        Task { @MainActor in
            // A moment for the window server to hand keyboard focus back to
            // the app underneath before the keystroke arrives.
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            let panelOpen = NSApp.windows.contains { $0 is LauncherPanel && $0.isVisible }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app,
                  NSPasteboard.general.changeCount == target.changeCount,
                  !panelOpen else { return }
            post()
        }
    }

    /// Posts ⌘V key down and up.
    static func post() {
        // The events carry their own flags, so keys the user is still holding
        // (⌘ after ⌘1 to ⌘9) don't change the shortcut. No local-event
        // suppression: it would drop the user's typing right after a pick.
        let source = CGEventSource(stateID: .combinedSessionState)

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
        // Translated with ⌘ held, as the event is posted: layouts like
        // "Dvorak - QWERTY ⌘" switch to another keymap under ⌘.
        let commandModifierState = UInt32((cmdKey >> 8) & 0xFF)

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), commandModifierState,
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
