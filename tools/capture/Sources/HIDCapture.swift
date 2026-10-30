import Foundation
import IOKit.hid

// Passive diagnostics only: no event posting, exclusive opens, or device writes.
// All callbacks and output run on the main run loop.
final class HIDCapture {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var seen: Set<String> = []
    private let started = ProcessInfo.processInfo.systemUptime
    private var failed = false

    static func run(_ arguments: [String]) throws {
        let arguments = arguments.isEmpty ? ["--hid-inventory"] : arguments
        let recording = arguments.first == "--hid-record"
        var products: [Int] = []
        if recording {
            guard arguments.count == 2, arguments[1].hasPrefix("--products=") else {
                throw CaptureError.invalid("Usage: --hid-record --products=0317,0084 (hex product IDs)")
            }
            let fields = arguments[1].dropFirst("--products=".count).split(separator: ",", omittingEmptySubsequences: false)
            for field in fields {
                guard let id = Int(field, radix: 16), (1...65535).contains(id) else {
                    throw CaptureError.invalid("Invalid Wacom product ID: \(field)")
                }
                products.append(id)
            }
        } else if arguments != ["--hid-inventory"] {
            throw CaptureError.invalid("Usage: --hid-inventory")
        }
        let capture = HIDCapture()
        let matches: [[String: Any]] = products.isEmpty ? [[kIOHIDVendorIDKey: 0x056A]] : products.map {
            [kIOHIDVendorIDKey: 0x056A, kIOHIDProductIDKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(capture.manager, matches as CFArray)
        let context = Unmanaged.passUnretained(capture).toOpaque()
        if recording {
            IOHIDManagerRegisterDeviceMatchingCallback(capture.manager, { context, result, _, device in
                guard let context else { return }
                let owner = Unmanaged<HIDCapture>.fromOpaque(context).takeUnretainedValue()
                if result == kIOReturnSuccess { owner.connected(device) }
                else { owner.emit(["event": "error", "operation": "connect", "code": result]) }
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(capture.manager, { context, result, _, device in
                guard let context else { return }
                let owner = Unmanaged<HIDCapture>.fromOpaque(context).takeUnretainedValue()
                let id = HIDCapture.identifier(device)
                owner.seen.remove(id)
                owner.emit(["event": "device_removed", "interface": id, "code": result])
            }, context)
            IOHIDManagerRegisterInputReportCallback(capture.manager, { context, result, sender, type, id, bytes, length in
                guard let context, let sender else { return }
                let owner = Unmanaged<HIDCapture>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                guard result == kIOReturnSuccess else {
                    owner.emit(["event": "error", "operation": "input_report", "interface": HIDCapture.identifier(device), "code": result])
                    return
                }
                owner.connected(device)
                owner.emit(["event": "report", "interface": HIDCapture.identifier(device), "report_type": type.rawValue,
                            "report_id": id, "length": length,
                            "hex": UnsafeBufferPointer(start: bytes, count: max(0, length)).map { String(format: "%02X", $0) }.joined(separator: " ")])
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(capture.manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDManagerClose(capture.manager, 0)
            IOHIDManagerUnscheduleFromRunLoop(capture.manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        let result = IOHIDManagerOpen(capture.manager, 0)
        guard result == kIOReturnSuccess else {
            throw CaptureError.invalid("HID access failed (\(result)). Allow Input Monitoring for the terminal/capture tool, quit other tablet drivers, and retry. No capture was started.")
        }
        let devices = (IOHIDManagerCopyDevices(capture.manager) as? Set<IOHIDDevice>) ?? []
        if !recording {
            guard !devices.isEmpty else {
                throw CaptureError.invalid("No tablet detected. Please connect your Wacom Tablet and restart the app")
            }
            let inventory: [String: Any] = ["schema_version": 1, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                          "interfaces": devices.map(Self.metadata).sorted { ($0["interface"] as? String ?? "") < ($1["interface"] as? String ?? "") }]
            let data = try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            return
        }
        for device in devices { capture.connected(device) }
        var timerContext = CFRunLoopTimerContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0, { _, context in
            guard let context else { return }
            let owner = Unmanaged<HIDCapture>.fromOpaque(context).takeUnretainedValue()
            let devices = (IOHIDManagerCopyDevices(owner.manager) as? Set<IOHIDDevice>) ?? []
            for device in devices {
                owner.emit(["event": "device_status", "interface": HIDCapture.identifier(device),
                            "transport": IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) ?? NSNull(),
                            "power_properties": HIDCapture.powerProperties(device)])
            }
        }, &timerContext)
        if let timer { CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.commonModes) }
        defer { if let timer { CFRunLoopTimerInvalidate(timer) } }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
            source.resume()
            return source
        }
        capture.emit(["event": "session_start", "schema_version": 1, "products": products, "interfaces": capture.seen.count])
        guard !capture.failed else { throw CaptureError.invalid("Could not write capture header.") }
        withExtendedLifetime((capture, signals)) { CFRunLoopRun() }
        capture.emit(["event": "session_end"])
        if capture.failed { throw CaptureError.invalid("Could not write capture output; recording stopped.") }
    }

    private static func identifier(_ device: IOHIDDevice) -> String {
        var registryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID) == KERN_SUCCESS {
            return String(format: "hid-%llX", registryID)
        }
        return "hid-\(CFHash(device))"
    }
    private static func powerProperties(_ device: IOHIDDevice) -> [String: Any] {
        var properties: [String: Any] = [:]
        for key in ["BatteryStrength", "BatteryPercent", "BatteryStatus", "BatteryStatusFlags", "BatteryIsCharging", "BatteryPowered", "SupportsBatteryCharging"] {
            if let value = IOHIDDeviceGetProperty(device, key as CFString),
               value is NSNumber || value is String { properties[key] = value }
        }
        return properties
    }
    private static func metadata(_ device: IOHIDDevice) -> [String: Any] {
        func value(_ key: String) -> Any { IOHIDDeviceGetProperty(device, key as CFString) ?? NSNull() }
        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement]) ?? []
        let fields: [[String: Any]] = elements.map { element in
            ["usage_page": IOHIDElementGetUsagePage(element), "usage": IOHIDElementGetUsage(element),
             "type": IOHIDElementGetType(element).rawValue, "report_id": IOHIDElementGetReportID(element),
             "report_size": IOHIDElementGetReportSize(element), "report_count": IOHIDElementGetReportCount(element),
             "logical_min": IOHIDElementGetLogicalMin(element), "logical_max": IOHIDElementGetLogicalMax(element),
             "physical_min": IOHIDElementGetPhysicalMin(element), "physical_max": IOHIDElementGetPhysicalMax(element),
             "unit": IOHIDElementGetUnit(element), "unit_exponent": IOHIDElementGetUnitExponent(element)]
        }
        let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
        return ["interface": identifier(device), "vendor_id": value(kIOHIDVendorIDKey), "product_id": value(kIOHIDProductIDKey),
                "product": value(kIOHIDProductKey), "manufacturer": value(kIOHIDManufacturerKey),
                "transport": value(kIOHIDTransportKey), "location_id": value(kIOHIDLocationIDKey),
                "usage_page": value(kIOHIDPrimaryUsagePageKey), "usage": value(kIOHIDPrimaryUsageKey),
                "max_input_report_size": value(kIOHIDMaxInputReportSizeKey), "max_output_report_size": value(kIOHIDMaxOutputReportSizeKey),
                "max_feature_report_size": value(kIOHIDMaxFeatureReportSizeKey),
                "report_descriptor_hex": descriptor.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "",
                "power_properties": powerProperties(device), "elements": fields]
    }
    private func connected(_ device: IOHIDDevice) {
        guard seen.insert(HIDCapture.identifier(device)).inserted else { return }
        emit(["event": "device_added", "device": Self.metadata(device)])
    }
    private func emit(_ fields: [String: Any]) {
        guard !failed else { return }
        var record = fields
        record["time"] = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        record["elapsed_us"] = Int64((ProcessInfo.processInfo.systemUptime - started) * 1_000_000)
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } catch {
            failed = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}
