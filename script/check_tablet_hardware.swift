import Foundation

@main
struct HardwareCheck {
    static func main() {
        let usb: [String: Any] = ["VendorID": 0x056A, "ProductID": 0x0317, "Product": "Intuos5 touch L", "Transport": "USB", "SerialNumber": "12345", "PrimaryUsagePage": 13]
        let receiver: [String: Any] = ["VendorID": 0x056A, "ProductID": 0x0084, "Product": "Wacom Wireless Receiver", "Transport": "USB", "PrimaryUsagePage": 13]
        assert(TabletHardware.detect(from: [receiver]) == nil, "A dongle is not a connected tablet")
        assert(TabletHardware.connectionKind(tablet: nil, receiverPresent: false) == .usb)
        assert(TabletHardware.connectionKind(tablet: nil, receiverPresent: true) == .receiver)
        let tablet = TabletHardware.detect(from: [receiver, usb])!
        assert(tablet.name == "Intuos5 touch L" && tablet.serial == "12345")
        assert(!tablet.bluetoothCapable && !tablet.bluetoothConnected, "USB presence does not establish Bluetooth")
        assert(TabletHardware.connectionKind(tablet: tablet, receiverPresent: true) == .receiver)
        var bt = usb
        bt["Transport"] = "Bluetooth Low Energy"
        let wireless = TabletHardware.detect(from: [bt])!
        assert(wireless.bluetoothConnected && wireless.bluetoothCapable)
        assert(TabletHardware.connectionKind(tablet: wireless, receiverPresent: true) == .bluetooth)
        bt["Transport"] = "USB"
        bt["SupportsBluetooth"] = true
        let capable = TabletHardware.detect(from: [bt])!
        assert(capable.bluetoothCapable && !capable.bluetoothConnected, "Capability is not an active connection")
        bt["SupportsBluetooth"] = false
        bt["SerialNumber"] = " "
        let noSerial = TabletHardware.detect(from: [bt])!
        assert(noSerial.serial == nil && !noSerial.bluetoothCapable)
        bt["VendorID"] = 0x1234
        assert(TabletHardware.detect(from: [bt]) == nil)
        assert(TabletHardware.detect(from: []) == nil, "Disconnect must clear stale identity")
        print("Tablet identity, unknown capabilities, receiver exclusion, and Bluetooth/receiver/USB cascade checks passed.")
        print("Live USB receiver: \(WacomReceiver.isPresent() ? "detected" : "not detected")")
    }
}
