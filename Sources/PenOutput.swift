import CoreGraphics

// Experimental user-space tablet delivery. All calls run on the HID run loop.
final class PenOutput {
    var posting = false
    var contactThreshold = 10
    var settings = DriverSettings()
    var flags: CGEventFlags = []
    var heldMouse: CGMouseButton?
    private var eventNumber: Int64 = 0
    private var down = false
    private var proximity = false
    private var toolID = 0
    private var location = CGPoint.zero

    func events(for sample: PenSample) -> [CGEvent] {
        var events: [CGEvent] = []
        let contact = sample.inProximity && sample.pressure > contactThreshold
        if sample.inProximity {
            location = settings.location(x: sample.x, y: sample.y, bounds: settings.displayBounds)
        }
        // Release the old tool before exiting proximity or switching tools.
        if down && (!contact || sample.toolID != toolID) {
            if let event = mouse(.leftMouseUp, sample: sample) { events.append(event) }
            down = false
        }
        if proximity && (!sample.inProximity || toolID != sample.toolID) {
            if let event = proximityEvent(entering: false, tool: toolID) { events.append(event) }
            proximity = false
        }
        if sample.inProximity {
            if !proximity {
                toolID = sample.toolID
                if let event = proximityEvent(entering: true, tool: toolID) { events.append(event) }
                proximity = true
            }
            let type: CGEventType = contact ? (down ? .leftMouseDragged : .leftMouseDown) :
                (heldMouse == .right ? .rightMouseDragged : (heldMouse == .center ? .otherMouseDragged : .mouseMoved))
            if let event = mouse(type, sample: sample) { events.append(event) }
            down = contact
        }
        return events
    }

    func accept(_ sample: PenSample) {
        let generated = events(for: sample)
        if posting { generated.forEach { $0.post(tap: .cghidEventTap) } }
    }

    private func mouse(_ type: CGEventType, sample: PenSample) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: type == .rightMouseDragged ? .right : (type == .otherMouseDragged ? .center : .left)) else { return nil }
        if type == .leftMouseDown { eventNumber += 1 }
        event.flags = event.flags.union(flags)
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        event.setIntegerValueField(.mouseEventSubtype, value: 1) // NSTabletPointEventSubtype
        event.setIntegerValueField(.tabletEventDeviceID, value: 1)
        event.setIntegerValueField(.tabletEventPointX, value: Int64(sample.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(sample.y))
        event.setIntegerValueField(.tabletEventPointButtons, value: type == .leftMouseUp ? 0 : Int64(sample.pressure > contactThreshold ? 1 : 0))
        let pressure = type == .leftMouseUp ? 0 : settings.pressure(sample.pressure)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: Double(sample.tiltX) / 64)
        event.setDoubleValueField(.tabletEventTiltY, value: Double(sample.tiltY) / 64)
        return event
    }

    private func proximityEvent(entering: Bool, tool: Int) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.type = .tabletProximity
        event.location = location
        for (field, value): (CGEventField, Int64) in [
            (.tabletProximityEventVendorID, 0x056A), (.tabletProximityEventTabletID, 0x0317),
            (.tabletProximityEventDeviceID, 1), (.tabletProximityEventSystemTabletID, 1),
            (.tabletProximityEventCapabilityMask, 0x05C7), // device, XY, buttons, tilt, pressure
            (.tabletProximityEventPointerID, Int64(tool)), (.tabletProximityEventVendorPointerType, Int64(tool)),
            (.tabletProximityEventPointerType, tool & 0xFFF == 0x80A ? 3 : 1),
            (.tabletProximityEventEnterProximity, entering ? 1 : 0)
        ] { event.setIntegerValueField(field, value: value) }
        return event
    }
}
