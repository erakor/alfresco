// DigitShortcuts.swift
//
// ⌘1 to ⌘9, used by both panels to pick one of the first nine rows.

import Carbon.HIToolbox

enum DigitShortcuts {
    /// Rows reachable with ⌘1 to ⌘9.
    static let count = 9

    /// Key code → digit. Key codes rather than characters, so the shortcuts
    /// also work on layouts like AZERTY where the top row types symbols
    /// without Shift.
    static let keyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3,
        kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6,
        kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9,
    ]
}
