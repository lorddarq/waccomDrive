import Foundation
import IOKit

// USB registry discovery does not open HID interfaces or need Input Monitoring.
enum WacomReceiver {
    static let productID = 0x0084
    static func isPresent() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        matching[kIOPropertyMatchKey] = ["idVendor": 0x056A, "idProduct": productID]
        let device = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard device != 0 else { return false }
        IOObjectRelease(device)
        return true
    }
}

struct TabletHardware: Equatable {
    enum ConnectionKind { case bluetooth, receiver, usb }
    let productID: Int
    let name: String
    let serial: String?
    let bluetoothCapable: Bool
    let bluetoothConnected: Bool

    static func connectionKind(tablet: TabletHardware?, receiverPresent: Bool) -> ConnectionKind {
        if tablet?.bluetoothCapable == true { return .bluetooth }
        return receiverPresent ? .receiver : .usb
    }
    static func detect(from properties: [[String: Any]]) -> TabletHardware? {
        let tablets = properties.filter {
            ($0["VendorID"] as? NSNumber)?.intValue == 0x056A &&
            ($0["ProductID"] as? NSNumber)?.intValue != WacomReceiver.productID &&
            (($0["PrimaryUsagePage"] as? NSNumber)?.intValue == 13 || ($0["ProductID"] as? NSNumber)?.intValue == 0x0317)
        }
        // Prefer the supported tablet when multiple Wacom devices are attached.
        let ids = Set(tablets.compactMap { ($0["ProductID"] as? NSNumber)?.intValue }).sorted()
        guard let id = ids.contains(0x0317) ? 0x0317 : ids.first else { return nil }
        let interfaces = tablets.filter { ($0["ProductID"] as? NSNumber)?.intValue == id }
        func text(_ key: String) -> String? {
            interfaces.compactMap { ($0[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.sorted().first
        }
        let connected = interfaces.contains { ($0["Transport"] as? String)?.localizedCaseInsensitiveContains("bluetooth") == true }
        let capable = connected || text("BluetoothAddress") != nil || interfaces.contains { ($0["SupportsBluetooth"] as? NSNumber)?.boolValue == true }
        return TabletHardware(productID: id, name: text("Product") ?? String(format: "Wacom tablet · 056A:%04X", id),
                              serial: text("SerialNumber"), bluetoothCapable: capable, bluetoothConnected: connected)
    }
    static func read() -> TabletHardware? {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return nil }
        matching[kIOPropertyMatchKey] = ["VendorID": 0x056A]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var properties: [[String: Any]] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            var values: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(device, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let value = values?.takeRetainedValue() as? [String: Any] { properties.append(value) }
            IOObjectRelease(device)
        }
        return detect(from: properties)
    }
}
