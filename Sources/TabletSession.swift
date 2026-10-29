import Foundation
import IOKit.hid
import CoreGraphics

// HID callbacks, timer, settings changes, and event posting share the main run loop.
final class TabletSession {
    var decoder = PenDecoder()
    let output = PenOutput()
    let buttons = ButtonMapper()
    var touchDecoder = TouchDecoder()
    let touch = TouchOutput()
    var lastPenReport = ProcessInfo.processInfo.systemUptime
    var onPen: ((PenSample) -> Void)?
    var onPad: ((PadSample) -> Void)?
    var onTouch: ((Int, String) -> Void)?
    var onConnection: ((Int, Bool) -> Void)?
    var onPower: ((TabletPowerStatus?) -> Void)?
    private var powerStatus: TabletPowerStatus?
    private var lastPowerReport = 0.0
    var onError: ((String) -> Void)?
    private var manager: IOHIDManager?
    private var watchdog: CFRunLoopTimer?
    private var devices: Set<CFHashCode> = []
    private var receivers: Set<CFHashCode> = []
    private var touchDevices: [CFHashCode: IOHIDDevice] = [:]
    private var seizedTouch: Set<CFHashCode> = []
    let decoded: Bool
    var logging: Bool

    init(decoded: Bool = true, posting: Bool = false, threshold: Int = 10, logging: Bool = true) {
        self.decoded = decoded
        self.logging = logging
        output.posting = posting
        buttons.posting = posting
        touch.posting = posting
        output.contactThreshold = threshold
    }
    func configure(_ settings: DriverSettings) {
        reset()
        buttons.configure(settings)
        output.settings = settings
        output.contactThreshold = settings.contactThreshold
        touch.configure(settings.touchSettings)
        touch.bounds = settings.displayBounds
        publishTouch()
    }
    func setPosting(_ enabled: Bool) {
        reset()
        output.posting = enabled
        buttons.posting = enabled
        touch.posting = enabled
        updateTouchOwnership()
        publishTouch()
    }
    func resetPen() {
        _ = buttons.pen(0)
        output.flags = buttons.flags
        output.heldMouse = buttons.heldMouse
        output.accept(decoder.reset())
        touch.updatePen(inRange: false)
        publishTouch()
    }
    func reset() {
        resetPen(); buttons.releaseAll()
        touch.reset(keeping: touchDecoder.contacts.values.sorted { $0.id < $1.id })
        publishTouch()
    }
    private func publishTouch() { onTouch?(touch.contacts.count, touch.status) }
    private func updateTouchOwnership() {
        for (key, device) in touchDevices {
            if output.posting && !seizedTouch.contains(key) {
                IOHIDDeviceClose(device, 0)
                if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
                    seizedTouch.insert(key)
                } else { _ = IOHIDDeviceOpen(device, 0) }
            } else if !output.posting && seizedTouch.contains(key) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                _ = IOHIDDeviceOpen(device, 0)
                seizedTouch.remove(key)
            }
        }
        touch.controlled = !touchDevices.isEmpty && seizedTouch.count == touchDevices.count
        publishTouch()
    }

    @discardableResult func start() throws -> Int {
        stop()
        guard let loop = CFRunLoopGetCurrent() else { throw SettingsError.invalid("No current run loop.") }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        let matches: [[String: Any]] = [0x0317, 0x0084].map {
            [kIOHIDVendorIDKey: 0x056A, kIOHIDProductIDKey: $0, kIOHIDTransportKey: "USB"]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context else { return }
            let session = Unmanaged<TabletSession>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess else { session.onError?("Device error: \(result)"); return }
            session.connection(device, connected: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let session = Unmanaged<TabletSession>.fromOpaque(context).takeUnretainedValue()
            session.connection(device, connected: false)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, type, id, report, length in
            guard let context, let sender else { return }
            let session = Unmanaged<TabletSession>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess else {
                session.touch.controlled = false
                session.reset()
                session.onError?("USB report error: \(result)")
                return
            }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            guard session.devices.contains(CFHash(device)), type == kIOHIDReportTypeInput, length > 0 else { return }
            session.report(Array(UnsafeBufferPointer(start: report, count: length)), id: id)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        guard result == kIOReturnSuccess else {
            stop()
            throw SettingsError.invalid("Cannot open HID manager (\(result)). Check Input Monitoring and sandbox restrictions.")
        }
        // Establish the initial inventory without waiting for the matching callbacks.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices { connection(device, connected: true) }
        }
        var timerContext = CFRunLoopTimerContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        watchdog = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0, { _, context in
            guard let context else { return }
            let session = Unmanaged<TabletSession>.fromOpaque(context).takeUnretainedValue()
            if session.powerStatus != nil && ProcessInfo.processInfo.systemUptime - session.lastPowerReport > 30 {
                session.powerStatus = nil
                session.onPower?(nil)
            }
            if ProcessInfo.processInfo.systemUptime - session.lastPenReport > 1, session.decoder.sample.inRange {
                session.resetPen()
                // Release a stale tip, but keep touch blocked until explicit pen state returns.
                session.touch.updatePen(inRange: true)
                session.publishTouch()
                session.onPen?(session.decoder.sample)
            }
        }, &timerContext)
        if let watchdog { CFRunLoopAddTimer(loop, watchdog, CFRunLoopMode.commonModes) }
        return self.devices.count
    }

    func stop() {
        reset()
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        watchdog = nil
        for (key, device) in touchDevices where seizedTouch.contains(key) {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        if let manager {
            IOHIDManagerClose(manager, 0)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        powerStatus = nil; onPower?(nil)
        devices.removeAll(); receivers.removeAll()
        touchDevices.removeAll(); seizedTouch.removeAll()
        touch.controlled = false
        touchDecoder.reset(); touch.reset()
        publishTouch()
        decoder = PenDecoder()
    }
    private func connection(_ device: IOHIDDevice, connected: Bool) {
        let id = CFHash(device)
        let receiver = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x84
        if receiver {
            if connected { receivers.insert(id) } else { receivers.remove(id) }
        } else {
            if connected {
                devices.insert(id)
                // Verified surface interface: vendor page FF00, usage 1, 64-byte reports.
                let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
                let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
                let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
                if page == 0xFF00 && usage == 1 && size == 64 { touchDevices[id] = device; updateTouchOwnership() }
            } else {
                powerStatus = nil; onPower?(nil)
                devices.remove(id); touchDevices.removeValue(forKey: id); seizedTouch.remove(id)
                reset(); decoder = PenDecoder(); touchDecoder.reset(); touch.reset()
                updateTouchOwnership()
                onPen?(decoder.sample); onPad?(PadSample(buttons: 0, ring: nil))
            }
        }
        onConnection?(devices.count, !receivers.isEmpty)
    }
    func report(_ bytes: [UInt8], id: UInt32) {
        if !decoded {
            print("id=\(id) bytes=\(bytes.count) \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return
        }
        if let status = TabletPowerStatus.decode(bytes) {
            lastPowerReport = ProcessInfo.processInfo.systemUptime
            if status != powerStatus { powerStatus = status; onPower?(status) }
            return
        }
        if let contacts = touchDecoder.decode(bytes) {
            touch.accept(contacts)
            publishTouch()
            return
        }
        if let pad = PadSample.decode(bytes) {
            buttons.location = CGEvent(source: nil)?.location ?? buttons.location
            _ = buttons.pad(pad.buttons)
            _ = buttons.ring(pad.ring)
            output.flags = buttons.flags
            output.heldMouse = buttons.heldMouse
            onPad?(pad)
            return
        }
        if let sample = decoder.decode(bytes) {
            lastPenReport = ProcessInfo.processInfo.systemUptime
            touch.updatePen(inRange: sample.inRange)
            publishTouch()
            if sample.inProximity {
                buttons.location = output.settings.location(x: sample.x, y: sample.y, bounds: output.settings.displayBounds)
            }
            _ = buttons.pen(sample.inProximity ? sample.buttons : 0)
            output.flags = buttons.flags
            output.heldMouse = buttons.heldMouse
            output.accept(sample)
            onPen?(sample)
            if logging { print("prox=\(sample.inProximity) x=\(sample.x) y=\(sample.y) pressure=\(sample.pressure) tilt=\(sample.tiltX),\(sample.tiltY) buttons=\(sample.buttons) tool=\(String(sample.toolID, radix: 16))") }
        }
    }
}
