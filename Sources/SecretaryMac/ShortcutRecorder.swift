import AppKit
import Carbon
import SwiftUI

/// Carbon virtual key codes and modifier flags required by RegisterEventHotKey.
struct RecordedShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static func from(_ event: NSEvent) -> RecordedShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var glyphs = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); glyphs += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); glyphs += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); glyphs += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); glyphs += "⌘" }
        // Shift by itself changes ordinary typing; require a command-like
        // modifier so recording cannot hijack normal text entry.
        guard carbon & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        let code = UInt32(event.keyCode)
        let name: String
        switch event.keyCode {
        case 49: name = "空格"
        case 36: name = "↩"
        case 48: name = "⇥"
        case 117: name = "⌦"
        case 51: return nil // Delete and Escape are reserved for editing/cancelling.
        case 122: name = "F1"
        case 120: name = "F2"
        case 99: name = "F3"
        case 118: name = "F4"
        case 96: name = "F5"
        case 97: name = "F6"
        case 98: name = "F7"
        case 100: name = "F8"
        case 101: name = "F9"
        case 109: name = "F10"
        case 103: name = "F11"
        case 111: name = "F12"
        default:
            // Key location is stable across keyboard layouts; present the
            // character typed in the current layout as the visible label.
            let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            name = raw.uppercased()
        }
        return RecordedShortcut(keyCode: code, modifiers: carbon, display: glyphs + name)
    }

    static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        var glyphs = ""
        if modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        let known: [UInt32: String] = [25: "9", 28: "8", 26: "7", 22: "6", 49: "空格", 36: "↩"]
        return glyphs + (known[keyCode] ?? "按键 \(keyCode)")
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recorded: RecordedShortcut?
    @Binding var isRecording: Bool
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        context.coordinator.parent = self
        if isRecording && view.window != nil && view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in guard let view else { return }; view.window?.makeFirstResponder(view) }
        }
    }

    final class Coordinator {
        var parent: ShortcutRecorder
        init(_ parent: ShortcutRecorder) { self.parent = parent }
    }

    final class RecorderView: NSView {
        var coordinator: Coordinator?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.isVisible, self.coordinator?.parent.isRecording == true else { return }
                window.makeFirstResponder(self)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            coordinator?.parent.isRecording = false
            coordinator?.parent.recorded = nil
            coordinator?.parent.onFinished()
        }

        override func keyDown(with event: NSEvent) {
            guard let coordinator, coordinator.parent.isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { // Esc cancels recording without changing the active shortcut.
                cancelOperation(nil)
                return
            }
            guard let combo = RecordedShortcut.from(event) else { NSSound.beep(); return }
            coordinator.parent.recorded = combo
            coordinator.parent.isRecording = false
            coordinator.parent.onFinished()
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard coordinator?.parent.isRecording == true else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
    }
}
