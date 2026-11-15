// xcrun swiftc -swift-version 6 -warnings-as-errors -D APP Sources/*.swift Sources/App/StringGuideOverlay.swift Sources/App/RulerOverlay.swift script/check_ruler_overlay.swift -o build/check-ruler-overlay
import AppKit
import QuartzCore

@main
@MainActor
struct RulerOverlayCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = RulerProbe()
        probe.start()
        app.run()
        withExtendedLifetime(probe) {}
    }
}
@MainActor
private final class RulerProbe {
    let overlay = RulerOverlay()
    var settings: RulerSettings? = RulerSettings()
    var oldLayers: [CAShapeLayer] = []
    var commits = 0
    var originalBounds = CGRect.zero
    var originalPanels: [NSWindow] = []
    func start() {
        overlay.onToggleEditing = { [weak self] in
            guard let self else { return }
            self.overlay.setEditing(true) { self.settings = $0 }
        }
        overlay.start { [weak self] in self?.settings }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.visible() }
        }
    }
    func visible() {
        let panels = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
        assert(panels.count == NSScreen.screens.count)
        let controls = NSApp.windows.filter { $0.title == "Ruler canvas controls" && $0.isVisible }
        assert(controls.count == NSScreen.screens.count)
        for panel in controls {
            assert(!panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
            let children = panel.contentView!.subviews
            assert(children.contains { ($0 as? NSButton)?.title == "Edit ruler" })
            assert(children.contains { ($0 as? NSPopUpButton)?.numberOfItems == RulerKind.allCases.count })
        }
        for panel in panels {
            assert(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
            assert(!panel.isOpaque && panel.level == .floating)
            let layers = panel.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            assert(layers.count == 2 && layers.allSatisfy { $0.path != nil && $0.animationKeys() == nil })
            oldLayers += layers
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.unchanged() }
        }
    }
    func unchanged() {
        let layers = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
            .flatMap { $0.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer } }
        assert(layers.count == oldLayers.count)
        assert(zip(layers, oldLayers).allSatisfy { $0 === $1 }, "Static guides must retain layers without rebuilding")
        overlay.setEditing(true) { [weak self] value in self?.commits += 1; self?.settings = value }
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(NSApp.windows.filter { $0.title == "Ruler canvas controls" && $0.isVisible }.allSatisfy {
            $0.contentView!.subviews.contains { ($0 as? NSButton)?.title == "Done" }
        })
        assert(handles.count == 2 && handles.allSatisfy { !$0.ignoresMouseEvents && !$0.canBecomeKey && $0.frame.width == 32 })
        assert(handles.contains { $0.contentView?.toolTip == "Move ruler" })
        assert(handles.contains { $0.contentView?.toolTip == "Rotate ruler" })
        originalPanels = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
        originalBounds = oldLayers[0].path!.boundingBoxOfPath
        overlay.updateDrag(.move, delta: CGPoint(x: 40, y: 15), finished: false)
        assert(commits == 0 && settings!.centerX == 700)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPreview() }
        }
    }
    func checkPreview() {
        let next = oldLayers[0].path!.boundingBoxOfPath
        assert(abs(next.minX - originalBounds.minX - 40) < 1e-6)
        assert(abs(next.minY - originalBounds.minY + 15) < 1e-6)
        assert(originalPanels.allSatisfy { $0.isVisible }, "Preview must retain guide windows")
        assert(commits == 0 && settings!.centerX == 700, "Preview must not change committed settings")
        overlay.updateDrag(.move, delta: CGPoint(x: 40, y: 15), finished: true)
        assert(commits == 1 && settings!.centerX == 740 && settings!.centerY == 465)
        overlay.updateDrag(.move, delta: CGPoint(x: 10, y: 10), finished: false)
        overlay.setEditing(false) { _ in assertionFailure("Cancel must not commit") }
        assert(commits == 1 && settings!.centerX == 740)
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") }.allSatisfy { !$0.isVisible })
        settings!.kind = .perspectiveEllipse
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEllipseHandles() }
        }
    }
    func checkEllipseHandles() {
        overlay.setEditing(true) { [weak self] value in self?.commits += 1; self?.settings = value }
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(handles.count == 11)
        assert(handles.contains { $0.contentView?.toolTip == "Resize ruler" })
        assert(handles.contains { $0.contentView?.toolTip == "Edge 1" })
        let old = settings!
        let collapse = CGPoint(x: old.corners[2].x - old.corners[0].x, y: old.corners[2].y - old.corners[0].y)
        overlay.updateDrag(.corner(0), delta: collapse, finished: false)
        overlay.updateDrag(.corner(0), delta: collapse, finished: true)
        assert(settings == old && commits == 1, "Invalid drag must neither preview invalid geometry nor commit")
        overlay.setEditing(false) { _ in }
        settings!.kind = .vanishing
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProxyHandles() }
        }
    }
    func checkProxyHandles() {
        overlay.setEditing(true) { _ in }
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(handles.count == 6)
        for i in handles.indices {
            for j in handles.indices where j > i {
                assert(hypot(handles[i].frame.midX - handles[j].frame.midX, handles[i].frame.midY - handles[j].frame.midY) >= 36,
                       "Off-screen vanishing points and transform handles must remain separately reachable")
            }
        }
        overlay.setEditing(false) { _ in }
        var contact = true
        overlay.isContact = { contact }
        overlay.onToggleEditing = { [weak self] in
            guard let self else { return }
            let visible = NSApp.windows.contains { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
            self.overlay.setEditing(!visible) { self.settings = $0 }
        }
        overlay.updateModifier(true)
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") }.allSatisfy { !$0.isVisible })
        contact = false
        overlay.updateModifier(true)
        assert(NSApp.windows.contains { $0.title.hasPrefix("Ruler handle") && $0.isVisible })
        overlay.updateModifier(false)
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") }.allSatisfy { !$0.isVisible })
        settings = nil
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                assert(NSApp.windows.filter { $0.title == "Ruler guide" || $0.title == "Ruler canvas controls" }.allSatisfy { !$0.isVisible })
                self?.overlay.stop()
                print("Ruler panels: click-through, non-activating, per-display placement, retained Core Animation layers, live preview without commit, move/rotate/edge/resize handles, cancellation/invalid geometry and hide passed.")
                NSApp.terminate(nil)
            }
        }
    }
}
