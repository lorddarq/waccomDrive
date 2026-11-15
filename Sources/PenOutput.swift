import CoreGraphics
import Foundation

// Experimental user-space tablet delivery. All calls run on the HID run loop.
final class PenOutput {
    var tablet: SupportedTablet = .large { didSet { string.reset(); velocity.reset(); ruler.reset() } }
    var posting = false
    var contactThreshold = 10
    var settings = DriverSettings() {
        didSet {
            string.reset()
            ruler.configure(settings.rulerSettings)
            velocity.reset()
            refreshDisplayBounds()
            compiledCurve = settings.advancedFeaturesEnabled ? settings.advancedPressureCurve.flatMap { $0.enabled ? CompiledPressureCurve($0) : nil } : nil
        }
    }
    private(set) var displayBounds = DriverSettings().displayBounds
    @discardableResult func refreshDisplayBounds() -> Bool {
        let next = settings.displayBounds
        guard next != displayBounds else { return false }
        displayBounds = next
        string.reset()
        ruler.reset()
        velocity.reset()
        return true
    }
    func mappedLocation(for sample: PenSample) -> CGPoint {
        settings.location(x: sample.x, y: sample.y, bounds: displayBounds, tabletSize: tablet.penSize)
    }
    func buttonLocation(for sample: PenSample) -> CGPoint {
        isContact && (stringLength > 0 || rulerActive) ? location : mappedLocation(for: sample)
    }
    var flags: CGEventFlags = []
    var heldMouse: CGMouseButton?
    private var eventNumber: Int64 = 0
    private var down = false
    private var proximity = false
    private var toolID = 0
    private var location = CGPoint.zero
    private var string = PulledString()
    private var ruler = RulerProjection()
    private var stringLocation = CGPoint.zero
    // Copied from UI only when overlay controls change; never query windows here.
    var overlayControlBounds: [CGRect] = []
    var overlayMenuTracking = false
    private var overlayControlContact = false
    var rulerActive: Bool { settings.advancedFeaturesEnabled && settings.rulerSettings.enabled }
    var rulerGuideSettings: RulerSettings? { posting && rulerActive && settings.rulerSettings.visible ? settings.rulerSettings : nil }
    var outputLocation: CGPoint { location }
    var rulerGuideAnchor: CGPoint { ruler.anchor ?? rawMappedLocation }
    var rulerGuideFamily: Int? {
        guard down, rulerActive, let anchor = ruler.anchor, let selected = ruler.selected else { return nil }
        return RulerGeometry.directions(settings.rulerSettings, anchor: anchor).firstIndex(of: selected)
    }
    private(set) var rawMappedLocation = CGPoint.zero
    var stringGuide: StringGuideSnapshot? {
        guard posting, down, !overlayControlContact, stringLength > 0, settings.stringSettings.guideVisible else { return nil }
        return StringGuideSnapshot(input: rawMappedLocation, output: stringLocation, length: stringLength, displayBounds: displayBounds)
    }
    private var stringLength: Double {
        settings.advancedFeaturesEnabled && settings.stringSettings.enabled ? settings.stringSettings.length : 0
    }

    private var compiledCurve: CompiledPressureCurve?
    private var filteredPressure = 0.0
    private var processor = PressureProcessor()
    private var velocity = PressureVelocity()
    var currentSpeed: Double { velocity.speed }
    var currentSpeedGain: Double { velocity.gain }
    var isContact: Bool { down }
    var outputPressure: Double { filteredPressure }

    func events(for sample: PenSample, time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [CGEvent] {
        var events: [CGEvent] = []
        let contact = sample.inProximity && sample.pressure > contactThreshold
        let mapped = sample.inProximity ? mappedLocation(for: sample) : nil
        if !contact || !down || toolID != sample.toolID {
            processor.reset()
            velocity.reset()
        }
        let speedGain: Double
        if contact, settings.advancedFeaturesEnabled, settings.speedSettings.enabled, let mapped {
            speedGain = velocity.update(mapped, time: time, settings: settings.speedSettings)
        } else {
            velocity.reset()
            speedGain = 1
        }
        let input = min(1, max(0, Double(sample.pressure) / 2047))
        let target = compiledCurve?.response(input) ?? settings.baselinePressureResponse(input)
        let processedPressure = contact ? processor.process(target, time: time, settings: settings) : 0
        filteredPressure = min(1, max(0, processedPressure * speedGain))
        let endingStroke = down && (!contact || sample.toolID != toolID)
        // Keep legacy release coordinates for exact bypass.
        if let mapped, stringLength == 0 && !rulerActive { location = mapped }
        // Release the old tool before exiting proximity or switching tools.
        if down && (!contact || sample.toolID != toolID) {
            if let event = mouse(.leftMouseUp, sample: sample) { events.append(event) }
            down = false
        }
        if proximity && (!sample.inProximity || toolID != sample.toolID) {
            if let event = proximityEvent(entering: false, tool: toolID) { events.append(event) }
            proximity = false
        }
        if !contact { string.reset(); ruler.reset(); overlayControlContact = false }
        if let mapped {
            rawMappedLocation = mapped
            if contact {
                if !down {
                    string.reset(); ruler.reset()
                    overlayControlContact = overlayMenuTracking || overlayControlBounds.contains { $0.contains(mapped) }
                }
                if overlayControlContact {
                    stringLocation = mapped; location = mapped
                } else {
                    stringLocation = string.process(mapped, length: stringLength)
                    location = rulerActive ? ruler.process(stringLocation, settings: settings.rulerSettings) : stringLocation
                }
            } else if !endingStroke || (stringLength == 0 && !rulerActive) {
                location = mapped
            }
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

    private(set) var timing = PenDeliveryTiming()
    func resetTiming() { timing = PenDeliveryTiming() }
    func recordMainLoopTick(_ time: Double) { timing.recordMainLoopTick(time) }
    func recordDiscoveryDuration(_ seconds: Double) { timing.recordDiscoveryDuration(seconds) }
    func accept(_ sample: PenSample) {
        let arrival = ProcessInfo.processInfo.systemUptime
        let generated = events(for: sample)
        if posting { generated.forEach { $0.post(tap: .cghidEventTap) } }
        timing.record(arrival: arrival, finished: ProcessInfo.processInfo.systemUptime,
                      inProximity: sample.inProximity, posted: posting ? generated.count : 0)
    }

    private func mouse(_ type: CGEventType, sample: PenSample) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: type == .rightMouseDragged ? .right : (type == .otherMouseDragged ? .center : .left)) else { return nil }
        if type == .leftMouseDown { eventNumber += 1 }
        // Preserve individual tablet movement samples through the event pipeline.
        event.flags = event.flags.union(flags).union(.maskNonCoalesced)
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        event.setIntegerValueField(.mouseEventSubtype, value: 1) // NSTabletPointEventSubtype
        event.setIntegerValueField(.tabletEventDeviceID, value: 1)
        event.setIntegerValueField(.tabletEventPointX, value: Int64(sample.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(sample.y))
        event.setIntegerValueField(.tabletEventPointButtons, value: type == .leftMouseUp ? 0 : Int64(sample.pressure > contactThreshold ? 1 : 0))
        let pressure = type == .leftMouseUp ? 0 : filteredPressure
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
            (.tabletProximityEventVendorID, 0x056A), (.tabletProximityEventTabletID, Int64(tablet.rawValue)),
            (.tabletProximityEventDeviceID, 1), (.tabletProximityEventSystemTabletID, 1),
            (.tabletProximityEventCapabilityMask, 0x05C7), // device, XY, buttons, tilt, pressure
            (.tabletProximityEventPointerID, Int64(tool)), (.tabletProximityEventVendorPointerType, Int64(tool)),
            (.tabletProximityEventPointerType, tool & 0xFFF == 0x80A ? 3 : 1),
            (.tabletProximityEventEnterProximity, entering ? 1 : 0)
        ] { event.setIntegerValueField(field, value: value) }
        return event
    }
}


// Bounded state, owned by the HID run loop; no disk or UI work.
struct PressureProcessor {
    private var value = 0.0
    private var previous: TimeInterval?
    private var start: TimeInterval?
    private var count = 0
    private var sum = 0.0
    private var held = false
    // Fixed ring bounds storage even at unexpectedly high report rates.
    private var samples = Array(repeating: (time: 0.0, value: 0.0), count: 1024)
    private var head = 0
    private var size = 0

    mutating func reset() {
        previous = nil; start = nil; count = 0; sum = 0; held = false
        head = 0; size = 0; value = 0
    }
    mutating func process(_ input: Double, time: TimeInterval, settings: DriverSettings) -> Double {
        guard input.isFinite, time.isFinite else { reset(); return 0 }
        if let previous, time < previous { reset() }
        let config = settings.processingSettings
        let advanced = settings.advancedFeaturesEnabled && config.enabled
        let mode = advanced ? config.mode : .ema
        let tau = (advanced ? config.emaMilliseconds : settings.smoothingMilliseconds) / 1000
        switch mode {
        case .bypass: value = input
        case .fixed: value = config.fixedValue
        case .sampleAndHold:
            if start == nil { start = time }
            if !held {
                if count > 0 && time - start! >= config.acquisitionMilliseconds / 1000 {
                    held = true
                } else {
                    sum += input; count += 1
                    value = sum / Double(count)
                    held = count >= config.sampleCount
                }
            }
        case .movingAverage:
            while size > 0 && (time - samples[head].time > config.windowMilliseconds / 1000 || size == samples.count) {
                sum -= samples[head].value
                head = (head + 1) % samples.count; size -= 1
            }
            samples[(head + size) % samples.count] = (time, input)
            sum += input; size += 1
            value = sum / Double(size)
        case .ema:
            if let previous, time > previous, time - previous < 0.1, tau > 0 {
                value += (input - value) * (1 - exp(-(time - previous) / tau))
            } else { value = input }
        }
        previous = time
        return min(1, max(0, value))
    }
}


// Constant-space distance filter; called once per real contact report.
struct PulledString {
    private var point: CGPoint?
    mutating func reset() { point = nil }
    mutating func process(_ input: CGPoint, length: Double) -> CGPoint {
        guard length > 0, let previous = point else { point = input; return input }
        let dx = input.x - previous.x, dy = input.y - previous.y
        let distance = hypot(dx, dy)
        guard distance > length else { return previous }
        let result = CGPoint(x: input.x - length * dx / distance, y: input.y - length * dy / distance)
        point = result
        return result
    }
}


struct StringGuideSnapshot: Equatable {
    let input: CGPoint
    let output: CGPoint
    let length: Double
    let displayBounds: CGRect
    var bounds: CGRect {
        CGRect(x: min(input.x, output.x - length), y: min(input.y, output.y - length),
               width: max(input.x, output.x + length) - min(input.x, output.x - length),
               height: max(input.y, output.y + length) - min(input.y, output.y - length))
            .insetBy(dx: -8, dy: -8)
    }
}


// Elapsed-time velocity on raw mapped coordinates, independent of position holding.
struct PressureVelocity {
    private var previous: (point: CGPoint, time: TimeInterval)?
    private(set) var speed = 0.0
    private(set) var gain = 1.0
    mutating func reset() { previous = nil; speed = 0; gain = 1 }
    mutating func update(_ point: CGPoint, time: TimeInterval, settings: PressureSpeedSettings) -> Double {
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { reset(); return 1 }
        defer { previous = (point, time) }
        guard let previous else { return 1 }
        let dt = time - previous.time
        guard dt >= 0.000001, dt <= 0.1 else { reset(); return 1 }
        let measured = hypot(point.x - previous.point.x, point.y - previous.point.y) / dt
        guard measured.isFinite else { reset(); return 1 }
        // Bound outliers and the live preview; gains already saturate by 10,000 points/s.
        let target = min(100000, measured)
        let tau = settings.averagingMilliseconds / 1000
        speed = tau > 0 ? speed + (target - speed) * (1 - exp(-dt / tau)) : target
        gain = settings.gain(at: speed)
        return gain
    }
}


// Bounded diagnostic window. Sorting/formatting happens only on explicit user request.
struct PenDeliveryTiming {
    private var intervals = Array(repeating: 0.0, count: 512)
    private var work = Array(repeating: 0.0, count: 512)
    private var head = 0, count = 0
    private var previous: Double?
    private(set) var reports = 0, postedEvents = 0
    private var previousTick: Double?
    private var maximumLoopGap = 0.0
    private var maximumDiscovery = 0.0
    mutating func recordMainLoopTick(_ time: Double) {
        if let previousTick { maximumLoopGap = max(maximumLoopGap, (time - previousTick) * 1000) }
        previousTick = time
    }
    mutating func recordDiscoveryDuration(_ seconds: Double) { maximumDiscovery = max(maximumDiscovery, seconds * 1000) }
    mutating func record(arrival: Double, finished: Double, inProximity: Bool, posted: Int) {
        guard inProximity else { previous = nil; return }
        reports += 1; postedEvents += posted
        if let previous, arrival >= previous {
            intervals[head] = (arrival - previous) * 1000
            work[head] = max(0, finished - arrival) * 1000
            head = (head + 1) % intervals.count; count = min(count + 1, intervals.count)
        }
        previous = arrival
    }
    var summary: String {
        guard count > 0 else { return "No pen timing samples yet. Move the pen in range, then copy again." }
        let spacing = Array(intervals.prefix(count)).sorted()
        let processing = Array(work.prefix(count)).sorted()
        let mean = spacing.reduce(0, +) / Double(count)
        let p95 = Int(Double(count - 1) * 0.95)
        func ms(_ value: Double) -> String { String(format: "%.3f", value) }
        return "Pen reports: \(reports); posted events: \(postedEvents); latest window: \(count) intervals\n" +
            "Callback rate: \(ms(mean > 0 ? 1000 / mean : 0)) reports/s\n" +
            "Callback spacing ms: mean \(ms(mean)), p95 \(ms(spacing[p95])), max \(ms(spacing.last!))\n" +
            "Processing + posting ms: p95 \(ms(processing[p95])), max \(ms(processing.last!))\n" +
            "Bunched callbacks <1 ms: \(spacing.filter { $0 < 1 }.count)\n" +
            "Gaps >12 ms: \(spacing.filter { $0 > 12 }.count); >20 ms: \(spacing.filter { $0 > 20 }.count)\n" +
            "Main-loop timer max gap ms (nominal 50): \(ms(maximumLoopGap))\n" +
            "Device discovery max duration ms: \(ms(maximumDiscovery))\n" +
            "Measures driver callback/processing time, not hardware timestamps or app/display latency."
    }
}
