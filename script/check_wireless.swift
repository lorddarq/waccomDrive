import Foundation
import CoreGraphics

@main
struct WirelessCheck {
    static func main() throws {
        let records = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(whereSeparator: \.isNewline)
        let session = TabletSession(posting: false, logging: false)
        var pens = 0, peakPressure = 0, peakTouches = 0, padBits = 0, rings = 0, wirelessStates = 0
        session.onPen = { sample in
            if sample.inProximity { pens += 1; peakPressure = max(peakPressure, sample.pressure) }
        }
        session.onTouch = { count, _ in peakTouches = max(peakTouches, count) }
        session.onPad = { sample in padBits |= sample.buttons; if sample.ring != nil { rings += 1 } }
        session.onWireless = { if $0?.supported == true { wirelessStates += 1 } }
        var firstStatus: [UInt8]?
        for line in records {
            let data = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard data["event"] as? String == "report", let hex = data["hex"] as? String else { continue }
            let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
            if firstStatus == nil, WirelessStatus.decode(bytes)?.supported == true { firstStatus = bytes }
            session.receiverReport(bytes, id: UInt32(data["report_id"] as! Int))
        }
        assert(wirelessStates > 0 && pens > 0 && peakPressure > 0 && peakTouches > 1 && rings > 0)
        assert(padBits & 0x1FE == 0x1FE, "All eight captured mechanical ExpressKeys must decode")
        assert(session.wirelessStatus?.supported == true)
        // A decoded receiver contact must retain the shared tap-to-click behavior.
        session.resetPen()
        var touchSettings = TouchSettings()
        touchSettings.enabled = true
        session.touch.configure(touchSettings)
        session.touch.reset()
        session.touch.controlled = true
        var finger = [UInt8](repeating: 0, count: 64)
        finger[0] = 2; finger[1] = 1; finger[2] = 2; finger[3] = 0x80
        finger[4] = 6; finger[5] = 6; finger[6] = 0x44
        session.receiverReport(finger, id: 2)
        let tap = session.touch.events(for: [], now: ProcessInfo.processInfo.systemUptime + 0.1, cursor: CGPoint(x: 100, y: 100))
        assert(tap.map(\.type) == [.leftMouseDown, .leftMouseUp], "Wireless contact must generate a tap click")
        session.touch.reset()
        session.touch.updatePen(inRange: true)
        session.receiverReport(finger, id: 2)
        assert(session.touch.events(for: [], now: ProcessInfo.processInfo.systemUptime + 0.1, cursor: .zero).isEmpty,
               "Pen-range palm rejection must block wireless taps")
        var status = firstStatus!
        assert(WirelessStatus.decode(Array(status.dropLast())) == nil, "Reject truncated monitor packets")
        status[5] = 0x9F
        assert(WirelessStatus.decode(status)?.power?.batteryPercent == 100)
        assert(WirelessStatus.decode(status)?.power?.charging == true)
        // Unknown paired models must not reach this tablet's pen decoder.
        status[6] = 0x03; status[7] = 0x15
        session.receiverReport(status, id: 128)
        let oldPens = pens
        session.receiverReport([2, 0xC2, 0x80, 0x24, 0xB8, 9, 0x5D, 0x31, 0, 0], id: 2)
        session.receiverReport([2, 0xE1, 0x19, 0x76, 0x38, 0xDC, 0x44, 0x66, 0x52, 0x4D], id: 2)
        assert(pens == oldPens && !session.decoder.sample.inRange)
        // A disconnect clears battery, tool proximity, buttons, and touch contacts.
        status[1] = 0
        session.receiverReport(status, id: 128)
        assert(session.wirelessStatus?.connected == false && !session.decoder.sample.inRange)
        assert(session.touch.contacts.isEmpty && session.buttons.heldMouse == nil)
        print("Captured wireless replay: \(pens) pen samples, peak pressure \(peakPressure), \(peakTouches) simultaneous touches, all eight ExpressKeys, \(rings) ring reports. No events posted.")
        print("Monitor validation, battery/charging, wireless tapping, palm rejection, unsupported-model rejection, and disconnect cleanup passed.")
    }
}
