import Foundation
import CoreGraphics

struct TouchContact: Equatable {
    let id: Int
    let x: Int
    let y: Int
}

struct TouchDecoder {
    private(set) var contacts: [Int: TouchContact] = [:]
    mutating func reset() { contacts.removeAll() }
    mutating func decode(_ bytes: [UInt8]) -> [TouchContact]? {
        guard bytes.count == 64, bytes[0] == 2 else { return nil }
        var changed = false
        for index in 0..<Int(bytes[1] & 7) {
            let offset = 2 + index * 8
            let id = Int(bytes[offset])
            guard (2...17).contains(id) else { continue }
            changed = true
            if bytes[offset + 1] & 0x80 != 0 {
                contacts[id] = TouchContact(id: id,
                    x: (Int(bytes[offset + 2]) << 4) | Int(bytes[offset + 4] >> 4),
                    y: (Int(bytes[offset + 3]) << 4) | Int(bytes[offset + 4] & 15))
            } else { contacts.removeValue(forKey: id) }
        }
        return changed ? contacts.values.sorted { $0.id < $1.id } : nil
    }
}

final class TouchOutput {
    var posting = false
    var controlled = false
    var settings = TouchSettings()
    var bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private(set) var penInRange = false
    private(set) var contacts: [TouchContact] = []
    private var waitForLift = false
    private var previous: CGPoint?
    private var previousIDs: [Int] = []
    private var lastTime = 0.0
    private var tapStart: Double?
    private var tapDistance = 0.0
    var status: String {
        if !posting { return "Driver paused" }
        if !controlled { return "Touch control unavailable" }
        if !settings.enabled { return "Off" }
        if settings.palmRejection && penInRange { return "Blocked while pen is in range" }
        if waitForLift { return "Lift fingers to resume touch" }
        return "On"
    }
    func configure(_ settings: TouchSettings) {
        self.settings = settings
        waitForLift = !contacts.isEmpty
        clearGesture()
    }
    func reset(keeping contacts: [TouchContact] = []) {
        self.contacts = contacts; waitForLift = !contacts.isEmpty; penInRange = false
        clearGesture()
    }
    func updatePen(inRange: Bool) {
        if inRange != penInRange {
            penInRange = inRange
            if settings.palmRejection && inRange { waitForLift = !contacts.isEmpty }
            clearGesture()
        }
    }
    private func clearGesture() {
        previous = nil; previousIDs = []; tapStart = nil; tapDistance = 0
    }
    func events(for contacts: [TouchContact], now: Double = ProcessInfo.processInfo.systemUptime, cursor: CGPoint) -> [CGEvent] {
        let priorCount = self.contacts.count
        self.contacts = contacts
        if !controlled || !settings.enabled || (settings.palmRejection && penInRange) {
            waitForLift = !contacts.isEmpty
            clearGesture()
            return []
        }
        if waitForLift {
            if contacts.isEmpty { waitForLift = false }
            clearGesture()
            return []
        }
        if now - lastTime > 1 { clearGesture() }
        lastTime = now
        if contacts.isEmpty {
            let click = settings.tapToClick && priorCount == 1 && tapStart.map { now - $0 <= 0.25 } == true && tapDistance <= 20
            clearGesture()
            guard click else { return [] }
            return [CGEventType.leftMouseDown, .leftMouseUp].compactMap { type in
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: 1)
                return event
            }
        }
        let point = CGPoint(x: Double(contacts.reduce(0) { $0 + $1.x }) / Double(contacts.count),
                            y: Double(contacts.reduce(0) { $0 + $1.y }) / Double(contacts.count))
        let ids = contacts.map(\.id)
        let old = previous
        previous = point
        let sameIDs = previousIDs == ids
        previousIDs = ids
        guard let old, sameIDs else {
            if priorCount == 0 && contacts.count == 1 { tapStart = now; tapDistance = 0 }
            else { tapStart = nil }
            return []
        }
        let dx = point.x - old.x, dy = point.y - old.y
        tapDistance += hypot(dx, dy)
        if contacts.count == 1 {
            guard dx != 0 || dy != 0 else { return [] }
            let location = CGPoint(x: min(bounds.maxX - 1, max(bounds.minX, cursor.x + dx * settings.pointerSpeed)),
                                   y: min(bounds.maxY - 1, max(bounds.minY, cursor.y + dy * settings.pointerSpeed)))
            return [CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)].compactMap { $0 }
        }
        tapStart = nil
        guard contacts.count == 2 else { return [] } // Three or more contacts never become pointer input.
        let horizontal = Int32(dx.rounded()), vertical = Int32(dy.rounded())
        guard horizontal != 0 || vertical != 0 else { return [] }
        return [CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)].compactMap { $0 }
    }
    func accept(_ contacts: [TouchContact]) {
        let generated = events(for: contacts, cursor: CGEvent(source: nil)?.location ?? .zero)
        if posting { generated.forEach { $0.post(tap: .cghidEventTap) } }
    }
}
