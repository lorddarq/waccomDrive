import Foundation

struct PenSample {
    var x = 0, y = 0, pressure = 0, tiltX = 0, tiltY = 0
    var inProximity = false
    var inRange = false
    var toolID = 0
    var buttons = 0
}

struct PenDecoder {
    private(set) var sample = PenSample()

    mutating func reset() -> PenSample {
        sample.inProximity = false
        sample.inRange = false
        sample.pressure = 0
        sample.buttons = 0
        return sample
    }

    mutating func decode(_ bytes: [UInt8]) -> PenSample? {
        guard bytes.count == 10, bytes[0] == 2 else { return nil }
        let b = bytes.map(Int.init)
        if b[1] & 0xFC == 0xC0 {
            _ = reset()
            sample.inRange = true
            sample.toolID = (b[2] << 4) | (b[3] >> 4) | ((b[7] & 15) << 16) | ((b[8] & 0xF0) << 8)
            // Release the previous tool; wait for position before entering proximity.
            return sample
        }
        if b[1] & 0xFE == 0x80 { return reset() }
        if b[1] & 0xFE == 0x20 {
            _ = reset()
            sample.inRange = true
            return sample
        }
        guard b[1] & 0xF8 == 0xE0, sample.toolID != 0 else { return nil }
        sample.x = ((b[2] << 8 | b[3]) << 1) | ((b[9] >> 1) & 1)
        sample.y = ((b[4] << 8 | b[5]) << 1) | (b[9] & 1)
        sample.pressure = (b[6] << 3) | ((b[7] >> 5) & 6) | (b[1] & 1)
        sample.tiltX = ((b[7] & 63) << 1 | (b[8] >> 7)) - 64
        sample.tiltY = (b[8] & 127) - 64
        sample.buttons = (b[1] >> 1) & 3
        sample.inProximity = true
        sample.inRange = true
        return sample
    }
}
