import Foundation

struct TabletPowerStatus: Equatable {
    let wirelessModuleInstalled: Bool
    let batteryPercent: Int?
    let charging: Bool?

    static func decode(_ bytes: [UInt8]) -> TabletPowerStatus? {
        guard bytes.count == 10, bytes[0] == 0xC0 else { return nil }
        return fromBatteryByte(bytes[8], moduleInstalled: bytes[9] & 0x02 != 0)
    }
    static func fromBatteryByte(_ byte: UInt8, moduleInstalled: Bool) -> TabletPowerStatus {
        guard moduleInstalled else {
            return TabletPowerStatus(wirelessModuleInstalled: false, batteryPercent: nil, charging: nil)
        }
        let level = Int(byte & 0x3F)
        let charging = byte & 0x80 != 0
        let percent = level <= 31 && (level > 0 || charging) ? level * 100 / 31 : nil
        return TabletPowerStatus(wirelessModuleInstalled: true, batteryPercent: percent, charging: charging)
    }

    var batteryIcon: String? {
        guard wirelessModuleInstalled else { return nil }
        if charging == true { return "battery-status-charging" }
        guard let batteryPercent else { return "battery-status-10-1" }
        switch batteryPercent {
        case ...10: return "battery-status-10"
        case ...20: return "battery-status-20"
        case ...50: return "battery-status-50"
        case ...80: return "battery-status-80"
        default: return "battery-status-full"
        }
    }
    var batteryDescription: String {
        batteryPercent.map { "\($0)%" } ?? (wirelessModuleInstalled ? "Not reported" : "Unavailable")
    }
    var chargingDescription: String {
        guard let charging else { return "Unavailable" }
        if charging { return "Charging" }
        return "Discharging"
    }
}
