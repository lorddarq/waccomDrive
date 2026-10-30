import Foundation

// Receiver monitor report, verified against a live 056A:0084 capture.
// Protocol reference: https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c (wacom_wireless_irq).
struct WirelessStatus: Equatable {
    let connected: Bool
    let productID: Int
    let power: TabletPowerStatus?
    var supported: Bool { connected && productID == 0x0317 }
    static func decode(_ bytes: [UInt8]) -> WirelessStatus? {
        guard bytes.count == 32, bytes[0] == 0x80 else { return nil }
        let connected = bytes[1] & 1 != 0
        return WirelessStatus(connected: connected,
                              productID: connected ? (Int(bytes[6]) << 8 | Int(bytes[7])) : 0,
                              power: connected ? .fromBatteryByte(bytes[5], moduleInstalled: true) : nil)
    }
}
