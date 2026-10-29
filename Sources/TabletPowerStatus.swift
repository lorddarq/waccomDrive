import Foundation

struct TabletPowerStatus: Equatable {
    let wirelessModuleInstalled: Bool
    let batteryPercent: Int?
    let charging: Bool?

    static func decode(_ bytes: [UInt8]) -> TabletPowerStatus? {
        guard bytes.count == 10, bytes[0] == 0xC0 else { return nil }
        guard bytes[9] & 0x02 != 0 else {
            return TabletPowerStatus(wirelessModuleInstalled: false, batteryPercent: nil, charging: nil)
        }
        let level = Int(bytes[8] & 0x3F)
        let charging = bytes[8] & 0x80 != 0
        // The device uses a 0...31 battery scale. Zero without charging does
        // not establish whether a battery is fitted; reserved levels are unknown.
        let percent = level <= 31 && (level > 0 || charging) ? level * 100 / 31 : nil
        return TabletPowerStatus(wirelessModuleInstalled: true, batteryPercent: percent, charging: charging)
    }

    var batteryDescription: String {
        batteryPercent.map { "\($0)%" } ?? (wirelessModuleInstalled ? "Not reported" : "Unavailable")
    }
    var chargingDescription: String {
        guard let charging else { return "Unavailable" }
        if charging { return "Charging" }
        return batteryPercent == 100 ? "Fully charged" : "Not charging"
    }
}
