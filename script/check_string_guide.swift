// Run from the repository root:
// xcrun swiftc -swift-version 6 -warnings-as-errors -D APP Sources/*.swift Sources/App/StringGuideOverlay.swift script/check_string_guide.swift -o build/check-string-guide
// build/check-string-guide
import AppKit
import QuartzCore

@main
@MainActor
struct StringGuideCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = Probe()
        probe.start()
        app.run()
        withExtendedLifetime(probe) {}
    }
}

@MainActor
private final class Probe {
    private let overlay = StringGuideOverlay()
    private var state: StringGuideSnapshot? = StringGuideSnapshot(
        input: CGPoint(x: 340, y: 300), output: CGPoint(x: 300, y: 300), length: 40, displayBounds: CGDisplayBounds(CGMainDisplayID()))
    func start() {
        overlay.start { [weak self] in self?.state }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkVisible() }
        }
    }
    private func checkVisible() {
        let panel = NSApp.windows.first { $0.title == "Pulled-string guide" }!
        assert(panel.isVisible && panel.ignoresMouseEvents)
        assert(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
        assert(!panel.isOpaque && panel.level == .floating)
        let rect = state!.displayBounds
        let top = NSScreen.screens.first!.frame.maxY
        assert(panel.frame == CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        let shapes = panel.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
        assert(shapes.count == 7 && shapes.allSatisfy { $0.path != nil && $0.animationKeys() == nil })
        let center = shapes.last!.path!.boundingBoxOfPath
        assert(center.midX == state!.output.x - rect.minX && center.midY == rect.maxY - state!.output.y)
        let old = state!
        state = StringGuideSnapshot(input: CGPoint(x: 500, y: 400), output: CGPoint(x: 460, y: 400),
                                    length: 40, displayBounds: old.displayBounds)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStationaryWindow() }
        }
    }
    private func checkStationaryWindow() {
        let panel = NSApp.windows.first { $0.title == "Pulled-string guide" }!
        let rect = state!.displayBounds
        let top = NSScreen.screens.first!.frame.maxY
        assert(panel.frame == CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        let center = (panel.contentView!.layer!.sublayers!.last as! CAShapeLayer).path!.boundingBoxOfPath
        assert(center.midX == state!.output.x - rect.minX && center.midY == rect.maxY - state!.output.y)
        state = nil
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHidden() }
        }
    }
    private func checkHidden() {
        assert(NSApp.windows.first { $0.title == "Pulled-string guide" }?.isVisible == false)
        overlay.stop()
        print("Native string guide: visible transparent panel, click-through, no focus, Quartz/AppKit placement and hide-on-lift passed.")
        NSApp.terminate(nil)
    }
}
