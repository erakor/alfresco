import AppKit

extension NSEvent {
    /// The modifiers that make a shortcut (⌘ ⌃ ⌥ ⇧), without Caps Lock,
    /// keypad Enter's .numericPad, .function or .help, so `== .command`
    /// means "⌘ and nothing else" whatever else is on.
    var shortcutModifiers: NSEvent.ModifierFlags {
        modifierFlags.intersection([.command, .control, .option, .shift])
    }
}
