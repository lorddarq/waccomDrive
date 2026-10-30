#if APP
import SwiftUI
import AppKit

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: CustomKeyShortcut?
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.record)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = { shortcut = $0 }
        button.shortcutTitle = shortcut?.label ?? "Record shortcut…"
        if button.monitor == nil { button.title = button.shortcutTitle }
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.stop() }
}

final class RecorderButton: NSButton {
    var onRecord: ((CustomKeyShortcut) -> Void)?
    var shortcutTitle = "Record shortcut…"
    var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    @objc func record() {
        stop()
        window?.makeFirstResponder(self)
        title = "Press keys… (Esc cancels)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else {
                self.stop(); return event
            }
            if event.keyCode != 53 {
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
                let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
                let prefix = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                    .filter { modifiers.contains($0.0) }.map(\.1).joined()
                if !key.isEmpty {
                    self.onRecord?(CustomKeyShortcut(keyCode: event.keyCode, modifiers: UInt64(modifiers.rawValue), label: prefix + key))
                }
            }
            self.stop()
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = shortcutTitle
    }
    override func resignFirstResponder() -> Bool { stop(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { stop() }; super.viewWillMove(toWindow: newWindow) }
}
#endif
