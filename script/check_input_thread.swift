// xcrun swiftc -swift-version 6 -warnings-as-errors -D APP Sources/*.swift Sources/App/TabletInputRuntime.swift script/check_input_thread.swift -o build/check-input-thread
import Foundation
import CoreFoundation

@main
struct InputThreadCheck {
    static func main() throws {
        let original = try JSONEncoder().encode(DriverSettings())
        let restored = try JSONDecoder().decode(DriverSettings.self, from: original)
        assert(restored.usesDedicatedInputThread, "New and older settings without a preference must default to dedicated input")
        var enabled = restored
        enabled.usesDedicatedInputThread = true
        let data = try JSONEncoder().encode(enabled)
        let roundTrip = try JSONDecoder().decode(DriverSettings.self, from: data)
        assert(roundTrip.usesDedicatedInputThread)
        enabled.usesDedicatedInputThread = false
        let disabled = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(enabled))
        assert(!disabled.usesDedicatedInputThread, "An explicit main-thread preference must survive loading")
        let text = try String(contentsOfFile: "captures/first-session-excerpt.txt", encoding: .utf8)
        let packets = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("id=") }.map {
            $0.split(whereSeparator: \.isWhitespace).dropFirst(2).compactMap { UInt8($0, radix: 16) }
        }
        var expected: [[State]] = []
        for dedicated in [false, true] {
            let runtime = TabletInputRuntime(dedicated: dedicated)
            runtime.perform { session in
                assert(Thread.isMainThread != dedicated)
                if dedicated { assert(Thread.current.qualityOfService == .userInteractive) }
                var settings = DriverSettings()
                settings.advancedFeaturesEnabled = true
                settings.advancedPressureCurve = EditablePressureCurve()
                settings.processingSettings.enabled = true
                settings.stringSettings.enabled = true
                settings.stringSettings.length = 10
                settings.rulerSettings.enabled = true
                settings.rulerSettings.kind = .isometric
                settings.rulerSettings.accuracy = 1
                settings.speedSettings.enabled = true
                settings.speedSettings.fastGain = 2
                session.configure(settings)
            }
            for index in 0..<1000 {
                assert(runtime.perform { _ in index } == index)
            }
            let signal = DispatchSemaphore(value: 0)
            runtime.perform { _ in
                let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { timer in
                    signal.signal()
                    if let timer { CFRunLoopTimerInvalidate(timer) }
                }
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            }
            // Deliberately stall the UI owner. Only dedicated input should keep running.
            Thread.sleep(forTimeInterval: 0.08)
            assert(signal.wait(timeout: .now()) == (dedicated ? .success : .timedOut))
            for mode in 0..<15 {
                runtime.perform { session in
                    session.reset()
                    var settings = session.output.settings
                    settings.rulerSettings.kind = mode == 0 || mode == 4 ? .isometric : (mode == 1 ? .radial : .perspective)
                    if (6..<9).contains(mode) { settings.rulerSettings.kind = .perspectiveEllipse }
                    if mode >= 9 { settings.rulerSettings.kind = .vanishing }
                    settings.rulerSettings.axisAngles = [20, 140, 90]
                    settings.rulerSettings.radialSettings.locked = false
                    settings.rulerSettings.radialSettings.bend = 0.3
                    settings.rulerSettings.camera = mode >= 2 ? RulerCamera() : nil
                    settings.rulerSettings.boxSettings.enabled = mode == 2 || mode == 3
                    settings.rulerSettings.boxSettings.learnsDimensions = mode == 3
                    settings.rulerSettings.changesAxesAutomatically = mode >= 4
                    if mode == 5 {
                        settings.rulerSettings.camera!.enableCustomAxes(true)
                        settings.rulerSettings.camera!.worldAxesSettings[0].incline = 15
                    }
                    if (6..<9).contains(mode) {
                        settings.rulerSettings.enableDepth(true)
                        settings.rulerSettings.depthSettings.offset = 30
                        settings.rulerSettings.depthSettings.scale = 1.2
                        settings.rulerSettings.ellipseSizing = RulerEllipseMode.allCases[mode - 6]
                    }
                    if mode >= 9 {
                        settings.rulerSettings.familyMeasurements = Array(repeating: RulerMeasurements(visible: true, distance: 40, divisions: 4), count: 3)
                        settings.rulerSettings.fixedReference = RulerPoint(x: 700, y: 600)
                        if mode == 10 { settings.rulerSettings.matchScene(true) }
                    }
                    if mode >= 11 {
                        settings.rulerSettings.kind = [RulerKind.straight, .parallel, .connected, .ellipse][mode - 11]
                        settings.rulerSettings.constructionSettings.bounded = true
                        settings.rulerSettings.constructionSettings.fixed = true
                        settings.rulerSettings.constructionSettings.tolerance = 5
                        settings.rulerSettings.constructionSettings.sizing = .concentric
                        settings.rulerSettings.constructionSettings.connect = true
                    }
                    session.configure(settings)
                }
                let trace = runtime.perform { session in
                    packets.enumerated().map { index, bytes in
                        session.report(bytes, id: UInt32(bytes.first ?? 0))
                        if mode == 3, index % 20 == 0 { _ = session.output.cycleRulerAxis() }
                        return State(x: session.output.outputLocation.x, y: session.output.outputLocation.y,
                                     contact: session.output.isContact)
                    }
                }
                if dedicated { assert(trace == expected[mode], "Threading must not change axis, radial, box, camera or depth-ellipse algorithms/lifecycle") }
                else { expected.append(trace) }
            }
            runtime.perform { session in
                session.reset()
                assert(!session.output.isContact)
                assert(session.buttons.releaseAll().isEmpty)
                assert(!session.processingChangePending)
            }
            runtime.close()
            runtime.close()
        }
        for _ in 0..<3 {
            let runtime = TabletInputRuntime(dedicated: true)
            runtime.perform { assert(!Thread.isMainThread); $0.reset() }
            runtime.close()
        }
        print("Input threading: default-on/explicit-off/JSON, owner confinement/QoS, progress during main-thread stall, all-features positional replay parity, release cleanup and repeated shutdown passed. No events posted.")
    }
    struct State: Equatable { let x: Double; let y: Double; let contact: Bool }
}
