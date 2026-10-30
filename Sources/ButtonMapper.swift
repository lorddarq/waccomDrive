import CoreGraphics

struct PadSample: Equatable {
    let buttons: Int
    let ring: Int?
    static func decode(_ bytes: [UInt8]) -> PadSample? {
        // PTH-851 Intuos5 pad report: 0x03, ring byte 2, center byte 3,
        // mechanical switches byte 4. Capacitive hover byte 5 is not a click.
        guard bytes.count == 10, bytes[0] == 3 else { return nil }
        return PadSample(buttons: (Int(bytes[4]) << 1) | (Int(bytes[3]) & 1),
                         ring: bytes[2] & 0x80 != 0 ? Int(bytes[2] & 0x7F) : nil)
    }
}

final class ButtonMapper {
    var onCyclePressureProfile: (() -> Void)?
    var onToggleTouch: (() -> Void)?
    var posting = false
    var location = CGPoint.zero
    private var active: Set<ButtonAction> = []
    private var activeShortcuts: Set<CustomKeyShortcut> = []
    private var penBits = 0, padBits = 0
    private var ringPosition: Int?
    private var ringRemainder = 0
    private var settings = DriverSettings()
    var heldMouse: CGMouseButton? { active.contains(.rightClick) ? .right : (active.contains(.middleClick) ? .center : nil) }
    var flags: CGEventFlags {
        active.reduce(CGEventFlags()) { $0.union(Self.modifier($1)?.1 ?? []) }
    }
    func configure(_ settings: DriverSettings) { releaseAll(); self.settings = settings }
    func pen(_ bits: Int) -> [CGEvent] { penBits = bits; return update() }
    func pad(_ bits: Int) -> [CGEvent] { padBits = bits; return update() }
    @discardableResult func releaseAll() -> [CGEvent] {
        penBits = 0; padBits = 0
        ringPosition = nil; ringRemainder = 0
        return update()
    }

    func ring(_ position: Int?) -> [CGEvent] {
        guard settings.ringSettings.enabled, let position, (0..<72).contains(position) else {
            ringPosition = nil; ringRemainder = 0
            return []
        }
        let previous = ringPosition
        ringPosition = position
        guard let previous else { return [] } // Touch-down establishes a baseline.
        var delta = position - previous
        if delta > 36 { delta -= 72 }
        if delta < -36 { delta += 72 }
        guard abs(delta) != 36 else { ringRemainder = 0; return [] } // Direction is ambiguous.
        if delta * ringRemainder < 0 { ringRemainder = 0 }
        ringRemainder += delta
        let steps = ringRemainder / settings.ringSettings.stepsPerShortcut
        ringRemainder %= settings.ringSettings.stepsPerShortcut
        let increase = settings.ringSettings.reversed ? steps < 0 : steps > 0
        var events: [CGEvent] = []
        for _ in 0..<abs(steps) { events += makeEvents(increase ? .brushLarger : .brushSmaller, down: true) }
        if posting { events.forEach { $0.post(tap: .cghidEventTap) } }
        return events
    }

    private func update() -> [CGEvent] {
        var next = Set<ButtonAction>()
        var nextShortcuts = Set<CustomKeyShortcut>()
        for (prefix, bits, actions) in [("pen", penBits, settings.penButtons), ("tablet", padBits, settings.tabletButtons)] {
            for (index, action) in actions.enumerated() where bits & (1 << index) != 0 && action != .none {
                if action == .customKey {
                    if let shortcut = settings[shortcut: "\(prefix).\(index)"] { nextShortcuts.insert(shortcut) }
                } else { next.insert(action) }
            }
        }
        let released = active.subtracting(next), pressed = next.subtracting(active)
        active = next
        var events: [CGEvent] = []
        for (actions, down) in [(released, false), (pressed, true)] {
            for action in actions.sorted(by: { $0.rawValue < $1.rawValue }) {
                events += makeEvents(action, down: down)
            }
        }
        for (shortcuts, down) in [(activeShortcuts.subtracting(nextShortcuts), false), (nextShortcuts.subtracting(activeShortcuts), true)] {
            for shortcut in shortcuts.sorted(by: { ($0.keyCode, $0.modifiers) < ($1.keyCode, $1.modifiers) }) {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down) {
                    event.flags = flags.union(CGEventFlags(rawValue: shortcut.modifiers))
                    events.append(event)
                }
            }
        }
        activeShortcuts = nextShortcuts
        if posting { events.forEach { $0.post(tap: .cghidEventTap) } }
        return events
    }

    private static func modifier(_ action: ButtonAction) -> (CGKeyCode, CGEventFlags)? {
        switch action {
        case .shift: (56, .maskShift)
        case .option: (58, .maskAlternate)
        case .command: (55, .maskCommand)
        case .control: (59, .maskControl)
        default: nil
        }
    }
    private func makeEvents(_ action: ButtonAction, down: Bool) -> [CGEvent] {
        if action == .cyclePressureProfile {
            if down && posting { onCyclePressureProfile?() }
            return []
        }
        if action == .toggleTouch {
            if down && posting { onToggleTouch?() }
            return []
        }
        if let modifier = Self.modifier(action) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier.0, keyDown: down) else { return [] }
            event.type = .flagsChanged
            event.flags = flags
            return [event]
        }
        if action == .rightClick || action == .middleClick {
            let right = action == .rightClick
            guard let event = CGEvent(mouseEventSource: nil,
                                      mouseType: right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp),
                                      mouseCursorPosition: location, mouseButton: right ? .right : .center) else { return [] }
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return [event]
        }
        let key: CGKeyCode
        let extra: CGEventFlags
        switch action {
        case .undo: key = 6; extra = .maskCommand
        case .redo: key = 6; extra = [.maskCommand, .maskShift]
        case .brush: key = 11; extra = []
        case .eraser: key = 14; extra = []
        case .brushSmaller: key = 33; extra = []
        case .brushLarger: key = 30; extra = []
        case .space: key = 49; extra = []
        default: return []
        }
        if action == .space {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return [] }
            event.flags = flags
            return [event]
        }
        guard down else { return [] }
        return [true, false].compactMap { pressed in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: pressed)
            event?.flags = flags.union(extra)
            return event
        }
    }
}
