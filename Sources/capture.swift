import Foundation
import IOKit.hid
import CoreGraphics

#if !APP
@main
struct Capture {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if ["--hid-inventory", "--hid-record"].contains(args.first ?? "") {
            do { try HIDCapture.run(Array(args)) }
            catch { fputs("Capture failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--self-check") { selfCheck(); return }
        if args.count == 1, let arg = args.first, arg.hasPrefix("--replay=") {
            do {
                let text = try String(contentsOfFile: String(arg.dropFirst(9)), encoding: .utf8)
                let session = TabletSession(logging: false)
                var count = 0, padCount = 0, maximumTouches = 0, powerReports = 0
                session.onPen = { if $0.inProximity { count += 1 } }
                session.onPad = { _ in padCount += 1 }
                session.onPower = { if $0 != nil { powerReports += 1 } }
                session.onTouch = { contacts, _ in maximumTouches = max(maximumTouches, contacts) }
                for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("id=") {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    guard fields.count >= 3, let length = Int(fields[1].dropFirst(6)) else {
                        throw NSError(domain: "Malformed capture line", code: 1)
                    }
                    let bytes = fields.dropFirst(2).compactMap { UInt8($0, radix: 16) }
                    guard bytes.count == length else { throw NSError(domain: "Malformed capture payload", code: 1) }
                    session.report(bytes, id: UInt32(bytes.first ?? 0))
                }
                session.reset()
                guard count + padCount + maximumTouches + powerReports > 0 else { throw NSError(domain: "No pen or pad samples", code: 1) }
                print("Replayed \(count) identified pen samples and \(padCount) pad reports; peak \(maximumTouches) surface contacts; \(powerReports) power status changes; no events posted.")
            } catch { fputs("Replay failed: \(error)\n", stderr); exit(1) }
            return
        }
        let posting = args.contains("--drive")
        let decoded = posting || args.contains("--decode")
        var threshold = 10
        for arg in args {
            if arg.hasPrefix("--threshold=") {
                guard let value = Int(arg.dropFirst("--threshold=".count)), (0...2046).contains(value) else {
                    fputs("Threshold must be an integer in 0...2046.\n", stderr); exit(1)
                }
                threshold = value
            } else if !["--probe", "--decode", "--drive"].contains(arg) {
                fputs("Usage: capture [--probe | --decode | --drive] [--threshold=10]\n", stderr); exit(1)
            }
        }
        if posting && !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            fputs("Enable Accessibility for the hosting application, then restart this command.\n", stderr)
            exit(1)
        }
        let session = TabletSession(decoded: decoded, posting: posting, threshold: threshold)
        let count: Int
        do { count = try session.start() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        defer { session.stop() }
        print("Matching USB interfaces: \(count)")
        if args.contains("--probe") { return }
        // Dispatch signal sources allow pen-up cleanup outside an async signal handler.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { CFRunLoopStop(CFRunLoopGetMain()) }
            source.resume()
            return source
        }
        print(posting ? "Experimental pen delivery active on the main display. Ctrl-C stops and releases the pen." : "Waiting for USB reports. Ctrl-C stops capture.")
        withExtendedLifetime((session, signals)) { CFRunLoopRun() }
    }

    static func selfCheck() {
        func packet(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }
        var decoder = PenDecoder()
        let entry = packet("02 C2 80 24 B8 09 5D 31 00 00")
        let hover = packet("02 E0 1D 44 39 B4 00 20 C0 FE")
        let contact = packet("02 E1 19 76 38 DC 44 66 52 4D")
        assert(decoder.decode(contact) == nil, "Require tool identity before input")
        assert(decoder.decode(entry)?.inProximity == false)
        let h = decoder.decode(hover)!
        assert(h.x == 14985 && h.y == 29544 && h.pressure == 0 && h.inProximity)
        let p = decoder.decode(contact)!
        assert(p.x == 13036 && p.y == 29113 && p.pressure == 547 && p.tiltX == 12 && p.tiltY == 18)
        assert(decoder.decode(Array(repeating: 0, count: 64)) == nil)
        assert(decoder.decode(Array(contact.prefix(9))) == nil)
        let output = PenOutput()
        assert(output.events(for: h).map(\.type) == [.tabletProximity, .mouseMoved])
        let down = output.events(for: p)
        assert(down.map(\.type) == [.leftMouseDown])
        assert(abs(down[0].getDoubleValueField(.tabletEventPointPressure) - 547.0 / 2047) < 0.001)
        assert(output.events(for: p).map(\.type) == [.leftMouseDragged])
        let exitSample = decoder.decode(packet("02 80 00 00 00 00 00 00 00 00"))!
        assert(!exitSample.inProximity && exitSample.pressure == 0)
        assert(output.events(for: exitSample).map(\.type) == [.leftMouseUp, .tabletProximity])
        assert(output.events(for: decoder.reset()).isEmpty)
        _ = decoder.decode(entry)
        let pressed = decoder.decode(contact)!
        _ = output.events(for: pressed)
        let range = decoder.decode(packet("02 20 29 63 4B 81 00 00 00 FF"))!
        assert(output.events(for: range).map(\.type) == [.leftMouseUp, .tabletProximity])
        _ = decoder.decode(entry)
        var buttonPacket = contact
        buttonPacket[1] = 0xE7
        assert(decoder.decode(buttonPacket)?.buttons == 3)
        var maximum = contact
        maximum[1] = 0xE1; maximum[6] = 255; maximum[7] = 255
        assert(decoder.decode(maximum)?.pressure == 2047)
        _ = output.events(for: decoder.decode(contact)!)
        let switched = decoder.decode(entry)!
        assert(output.events(for: switched).map(\.type) == [.leftMouseUp, .tabletProximity])
        do { try checkSettingsAndButtons() }
        catch { fputs("Settings check failed: \(error)\n", stderr); exit(1) }
        print("Pen decoding and event lifecycle checks passed (no events posted).")
    }
}

#endif
