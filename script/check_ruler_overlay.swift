// xcrun swiftc -swift-version 6 -warnings-as-errors -D APP Sources/*.swift Sources/App/StringGuideOverlay.swift Sources/App/RulerPicker.swift Sources/App/RulerOverlay.swift script/check_ruler_overlay.swift -o build/check-ruler-overlay
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
    var pickerInvocations = 0
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
    func checkSymbols() {
        for panel in NSApp.windows where panel.title.hasPrefix("Ruler handle") && panel.isVisible {
            assert(panel.contentView!.subviews.contains { ($0 as? NSImageView)?.image != nil && $0.frame.size == CGSize(width: 16, height: 16) }, "Missing SF Symbol for \(panel.title)")
        }
    }
    func visible() {
        let panels = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
        assert(panels.count == NSScreen.screens.count)
        assert(NSApp.windows.allSatisfy { $0.title != "Ruler canvas controls" }, "No floating selector/edit toolbar should exist")
        for panel in panels {
            assert(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
            assert(!panel.isOpaque && panel.level == .floating)
            let layers = panel.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            assert(layers.count == 2 && layers.allSatisfy { $0.path != nil && $0.animationKeys() == nil })
            assert(layers.allSatisfy { $0.lineWidth == 1 && abs(Double($0.opacity) - settings!.opacity) < 1e-6 }, "Guides must use their full configured opacity and a full-point colored stroke")
            assert(layers[0].strokeColor == settings!.guideNSColor(at: 0).cgColor, "One colored layer per path; no dark under-stroke")
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
        checkSymbols()
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(handles.count == 6 && handles.allSatisfy { !$0.ignoresMouseEvents && !$0.canBecomeKey && $0.frame.width == 32 })
        assert(handles.allSatisfy { panel in
            panel.contentView!.subviews.contains { ($0 as? NSImageView)?.image != nil && $0.frame == CGRect(x: 8, y: 8, width: 16, height: 16) }
        }, "SF Symbols must occupy a centered 16×16 area inside their larger click targets")
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
        checkSymbols()
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(handles.count == 14)
        assert(handles.contains { $0.contentView?.toolTip == "Resize ruler" })
        assert(handles.contains { $0.contentView?.toolTip == "Edge 1" })
        let old = settings!
        let collapse = CGPoint(x: old.corners[2].x - old.corners[0].x, y: old.corners[2].y - old.corners[0].y)
        overlay.updateDrag(.corner(0), delta: collapse, finished: false)
        overlay.updateDrag(.corner(0), delta: collapse, finished: true)
        assert(settings == old && commits == 1, "Invalid drag must neither preview invalid geometry nor commit")
        overlay.updateDrag(.ellipseDepthMode, delta: .zero, finished: true)
        assert(settings!.depthSettings.enabled)
        checkSymbols()
        overlay.updateDrag(.ellipseDepth, delta: CGPoint(x: 0, y: 30), finished: false)
        assert(settings!.depthSettings.offset == 0, "Depth preview must not commit")
        overlay.updateDrag(.ellipseDepth, delta: CGPoint(x: 0, y: 30), finished: true)
        assert(settings!.depthSettings.offset != 0 && settings!.corners == old.corners)
        overlay.updateDrag(.ellipseScale, delta: CGPoint(x: 30, y: 0), finished: true)
        assert(settings!.depthSettings.scale > 1)
        overlay.updateDrag(.ellipseSceneMode, delta: .zero, finished: true)
        assert(settings!.depthSettings.sceneLines?.count == 4)
        checkSymbols()
        let layers = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
            .flatMap { $0.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer } }
        assert(layers.count == NSScreen.screens.count * 3, "Depth must use a third retained colored path")
        settings = old
        overlay.setEditing(false) { _ in }
        settings!.kind = .vanishing
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProxyHandles() }
        }
    }
    func checkProxyHandles() {
        overlay.setEditing(true) { _ in }
        checkSymbols()
        let handles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(handles.count == 10)
        for i in handles.indices {
            for j in handles.indices where j > i {
                assert(hypot(handles[i].frame.midX - handles[j].frame.midX, handles[i].frame.midY - handles[j].frame.midY) >= 36,
                       "Off-screen handles overlap: \(handles[i].title) \(handles[i].frame), \(handles[j].title) \(handles[j].frame)")
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
        settings!.kind = .perspective
        settings!.camera = RulerCamera()
        settings!.measureSettings.visible = true
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        checkSymbols()
        let cameraHandles = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
        assert(cameraHandles.count == 12)
        assert(cameraHandles.contains { $0.contentView?.toolTip == "Camera field of view" })
        overlay.updateDrag(.cameraMode, delta: .zero, finished: false)
        overlay.updateDrag(.cameraMode, delta: .zero, finished: true)
        assert(settings!.camera!.points == 1, "Camera mode must be available on canvas")
        settings!.camera!.enableCustomAxes(true)
        settings!.circlePlane = .xy
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        checkSymbols()
        overlay.updateDrag(.cameraAxis(0), delta: CGPoint(x: 30, y: 15), finished: true)
        assert(settings!.camera!.worldAxesSettings[0].azimuth == 10 && settings!.camera!.worldAxesSettings[0].incline == 5)
        let cameraSettings = settings!
        overlay.updateDrag(.cameraCircle, delta: .zero, finished: true)
        assert(settings!.kind == .perspectiveEllipse && settings!.corners.count == 4)
        settings = cameraSettings
        overlay.setEditing(false) { _ in }
        overlay.selectedFamily = { 1 }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkActiveAxis() }
        }
    }
    func checkColorOnBackgrounds(_ source: CAShapeLayer) {
        for background in [0.0, 1.0] {
            var pixels = [UInt8](repeating: 0, count: 32 * 16 * 4)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.setFillColor(CGColor(gray: background, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
                let root = CALayer(); root.frame = CGRect(x: 0, y: 0, width: 32, height: 16)
                let stroke = CAShapeLayer(); stroke.frame = root.bounds
                stroke.strokeColor = source.strokeColor; stroke.opacity = source.opacity; stroke.lineWidth = source.lineWidth; stroke.fillColor = nil
                let path = CGMutablePath(); path.move(to: CGPoint(x: 0, y: 8.5)); path.addLine(to: CGPoint(x: 32, y: 8.5)); stroke.path = path
                root.addSublayer(stroke); root.render(in: context)
            }
            for (channel, component) in [0.2, 0.4, 0.6].enumerated() {
                let actual = Double(pixels[(7 * 32 + 16) * 4 + channel]) / 255
                let expected = component * Double(source.opacity) + background * (1 - Double(source.opacity))
                assert(abs(actual - expected) < 0.025, "Guide color must composite without a dark under-stroke on black and white")
            }
        }
    }
    func checkActiveAxis() {
        let panels = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
        for panel in panels {
            let layers = panel.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            assert(layers.count == 3)
            assert(layers[1].lineWidth > layers[0].lineWidth && layers[1].opacity > layers[0].opacity,
                   "The selected direction must be emphasized without adding windows")
        }
        let retained = panels.map { $0.contentView!.layer!.sublayers![0] as! CAShapeLayer }
        settings!.setGuideColor(RulerGuideColor(red: 0.2, green: 0.4, blue: 0.6), at: 0)
        overlay.setEditing(false) { _ in }
        for (panel, oldLayer) in zip(panels, retained) {
            let layer = panel.contentView!.layer!.sublayers![0] as! CAShapeLayer
            assert(layer === oldLayer, "Color changes must reuse layers")
            let color = NSColor(cgColor: layer.strokeColor!)!.usingColorSpace(.sRGB)!
            assert(abs(color.redComponent - 0.2) < 1e-6 && abs(color.greenComponent - 0.4) < 1e-6 && abs(color.blueComponent - 0.6) < 1e-6)
            checkColorOnBackgrounds(layer)
        }
        settings!.resetGuideColors()
        overlay.setEditing(false) { _ in }
        for panel in panels {
            let layer = panel.contentView!.layer!.sublayers![0] as! CAShapeLayer
            assert(layer.strokeColor == settings!.guideNSColor(at: 0).cgColor, "Reset must restore the default stroke color")
        }
        settings!.kind = .vanishing
        settings!.matchScene(true)
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }.count == 19)
        overlay.updateDrag(.sceneMode, delta: .zero, finished: true)
        assert(settings!.sceneLines == nil)
        overlay.updateDrag(.horizon, delta: .zero, finished: true)
        assert(settings!.showsHorizon)
        settings!.fixedReference = RulerPoint(x: 700, y: 600)
        settings!.familyMeasurements = Array(repeating: settings!.measureSettings, count: 3)
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        checkSymbols()
        let before = settings!.measurement(for: 0).distance
        overlay.updateDrag(.familyMeasure(0), delta: CGPoint(x: 20, y: 0), finished: true)
        assert(settings!.measurement(for: 0).distance != before)
        settings!.familyMeasurements = nil
        settings!.fixedReference = nil
        overlay.setEditing(false) { _ in }
        settings!.kind = .radial
        settings!.radialSettings.bend = 0.4
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }.count == 6)
        overlay.updateDrag(.radialMode, delta: .zero, finished: true)
        checkSymbols()
        assert(!settings!.radialSettings.locked)
        overlay.updateDrag(.radialBend, delta: CGPoint(x: 0, y: 40), finished: true)
        assert(abs(settings!.radialSettings.bend - 0.6) < 1e-9)
        settings!.kind = .isometric
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }.count == 10)
        overlay.updateDrag(.isometricAxis(1), delta: CGPoint(x: 0, y: 30), finished: true)
        checkSymbols()
        assert(settings!.axisAngles != nil && settings!.isometricAngles[0] == settings!.angle && settings!.isometricAngles[2] == 90)
        overlay.updateDrag(.isometricPreset, delta: .zero, finished: true)
        assert(settings!.axisAngles == nil && settings!.angle == 30)
        overlay.updateDrag(.isometricPreset, delta: .zero, finished: true)
        assert(settings!.isometricPreset == 1)
        overlay.updateDrag(.reference, delta: .zero, finished: true)
        assert(settings!.fixedReference != nil)
        checkSymbols()
        let reference = settings!.fixedReference!
        overlay.updateDrag(.reference, delta: CGPoint(x: 20, y: 10), finished: true)
        assert(settings!.fixedReference!.x == reference.x + 20 && settings!.fixedReference!.y == reference.y + 10)
        overlay.updateDrag(.reference, delta: .zero, finished: true)
        assert(settings!.fixedReference == nil)
        overlay.updateDrag(.boxMode, delta: .zero, finished: true)
        assert(settings!.boxSettings.enabled)
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }.count == 14)
        overlay.updateDrag(.boxSize(0), delta: CGPoint(x: 20, y: 0), finished: true)
        assert(settings!.boxSettings.extents[0] > 100)
        overlay.updateDrag(.boxLearn, delta: .zero, finished: true)
        assert(settings!.boxSettings.learnsDimensions)
        checkSymbols()
        assert(NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }.count == 11)
        overlay.updateDrag(.boxLearn, delta: .zero, finished: true)
        assert(!settings!.boxSettings.learnsDimensions)
        for panel in NSApp.windows where panel.title == "Ruler guide" && panel.isVisible {
            let layers = panel.contentView!.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            assert(layers.count == 3 && layers.allSatisfy { $0.path!.boundingBoxOfPath.width < 1000 }, "Bounded box must replace infinite axes with the shared wireframe")
        }
        overlay.setEditing(false) { _ in }
        checkKeyboardEditing()
        checkCompactEllipseHandles()
        checkNewFamilies()
        checkPicker()
        settings = nil
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                assert(NSApp.windows.filter { $0.title == "Ruler guide" }.allSatisfy { !$0.isVisible })
                self?.overlay.stop()
                print("Ruler panels: click-through, non-activating, per-display placement, retained Core Animation layers, live preview without commit, move/rotate/edge/resize handles, cancellation/invalid geometry and hide passed.")
                NSApp.terminate(nil)
            }
        }
    }
    func checkNewFamilies() {
        for kind in [RulerKind.straight, .parallel, .connected, .ellipse] {
            settings = RulerSettings(); settings!.enabled = true; settings!.kind = kind
            overlay.setEditing(true) { [weak self] in self?.settings = $0 }
            checkSymbols()
            let guides = NSApp.windows.filter { $0.title == "Ruler guide" && $0.isVisible }
            assert(guides.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey })
            let original = settings!
            overlay.updateDrag(.move, delta: CGPoint(x: 12, y: 8), finished: true)
            assert(hypot(settings!.editingCenter.x - original.editingCenter.x - 12, settings!.editingCenter.y - original.editingCenter.y - 8) < 1e-6)
            overlay.setEditing(false) { _ in }
        }
        print("New family native guides: click-through panels, symbols, handles and committed movement passed.")
    }
    func checkPicker() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -400, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 200, height: 140)] {
            for anchor in [CGPoint(x: screen.midX, y: screen.midY), CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.minY)] {
                let layout = RulerPickerLayout(anchor: anchor, screen: screen)!
                assert(screen.insetBy(dx: 16, dy: 16).contains(layout.frame))
                for (i, center) in layout.centers.enumerated() {
                    let target = CGRect(x: center.x - 24 * layout.scale, y: center.y - 24 * layout.scale, width: 48 * layout.scale, height: 48 * layout.scale)
                    assert(CGRect(origin: .zero, size: layout.frame.size).contains(target))
                    assert(layout.hit(CGPoint(x: layout.frame.minX + center.x, y: layout.frame.minY + center.y)) == i)
                }
                assert(layout.hit(CGPoint(x: screen.minX - 1000, y: screen.minY - 1000)) == nil)
                if anchor.y == screen.maxY { assert(!layout.opensUp) }
            }
        }
        assert(RulerPickerLayout(anchor: .zero, screen: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        let frame = NSScreen.screens.first!.visibleFrame
        var chosen: RulerPickerAction?
        assert(overlay.picker.present(current: .perspectiveEllipse, anchor: CGPoint(x: frame.midX, y: frame.midY), screens: [frame]) { chosen = $0 })
        let panel = NSApp.windows.first { $0.title == "Ruler picker" && $0.isVisible }!
        assert(!panel.canBecomeKey && !panel.canBecomeMain && panel.frame.width <= 508 && panel.frame.height <= 300)
        let buttons = panel.contentView!.subviews.compactMap { $0 as? NSButton }
        assert(buttons.count == RulerPickerAction.all.count && buttons.allSatisfy { $0.image != nil && $0.toolTip != nil })
        let view = panel.contentView!
        panel.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try! png.write(to: URL(fileURLWithPath: "build/ruler-picker-preview.png"))
            }
        }
        assert(buttons[RulerKind.allCases.count].toolTip == "Turn ruler off · Guide and snapping")
        buttons[RulerKind.allCases.count].performClick(nil); assert(chosen == .toggleRuler)
        buttons[1].performClick(nil); assert(chosen == .ruler(.isometric))
        overlay.picker.navigate(RulerKind.allCases.count - 4); assert(overlay.picker.choice == .toggleRuler)
        overlay.picker.navigate(1); assert(overlay.picker.choice == .ruler(.perspective))
        let layout = overlay.picker.layout!, center = layout.centers[2]
        let native = CGPoint(x: layout.frame.minX + center.x, y: layout.frame.minY + center.y)
        overlay.picker.hover(at: native); assert(overlay.picker.choice == .ruler(.vanishing))
        assert(overlay.keyboardEvent(key: 124, flags: [], down: true, ownApp: false))
        assert(overlay.picker.choice == .ruler(.radial))
        assert(overlay.keyboardEvent(key: 124, flags: [], down: false, ownApp: false))
        // Direct presentation leaves the test coordinate origin at zero; no OS events are posted.
        let point = CGPoint(x: native.x, y: -native.y)
        assert(overlay.pickerPointer(type: .leftMouseDown, point: point))
        assert(overlay.pickerPointer(type: .rightMouseDown, point: point))
        assert(overlay.keyboardEvent(key: 53, flags: [], down: true, ownApp: false), "Escape must cancel even during a captured click")
        overlay.finishPicker(nil)
        assert(!overlay.pickerVisible)
        assert(overlay.pickerPointer(type: .leftMouseDragged, point: point))
        assert(overlay.pickerPointer(type: .leftMouseUp, point: point))
        assert(overlay.pickerPointer(type: .rightMouseUp, point: point))
        assert(overlay.keyboardEvent(key: 53, flags: [], down: false, ownApp: false))
        assert(!overlay.pickerPointer(type: .leftMouseDown, point: point), "Normal painting input must pass when picker is closed")
        assert(overlay.picker.present(current: .isometric, rulerEnabled: false, anchor: CGPoint(x: frame.midX, y: frame.midY), screens: [frame]) { chosen = $0 })
        let hiddenButtons = panel.contentView!.subviews.compactMap { $0 as? NSButton }
        assert(hiddenButtons[RulerKind.allCases.count].toolTip == "Turn ruler on · Guide and snapping")
        hiddenButtons[RulerKind.allCases.count].performClick(nil); assert(chosen == .toggleRuler)
        overlay.finishPicker(nil)
        let shortcut = DriverSettings().pickerShortcut!
        overlay.pickerShortcut = { shortcut }
        overlay.onTogglePicker = { [weak self] in self?.pickerInvocations += 1 }
        assert(overlay.keyboardEvent(key: shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), down: true, ownApp: false))
        assert(overlay.keyboardEvent(key: shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), down: true, ownApp: false, repeatKey: true))
        assert(overlay.keyboardEvent(key: shortcut.keyCode, flags: [], down: false, ownApp: false))
        assert(!overlay.keyboardEvent(key: shortcut.keyCode, flags: CGEventFlags(rawValue: shortcut.modifiers), down: true, ownApp: true), "Recorder must receive the binding in driver settings")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            assert(self.pickerInvocations == 1, "Shortcut repeats must not reopen/toggle the picker")
            self.overlay.pickerShortcut = nil; self.overlay.onTogglePicker = nil
        }
        print("Ruler picker: semicircle/display-edge/negative-origin layout, hit testing, symbols, non-key panel, keyboard navigation, pointer capture/cleanup and shortcut repeat/focus guards passed. No events posted.")
    }
    func checkCompactEllipseHandles() {
        let screen = NSScreen.screens.first!, top = screen.frame.maxY, frame = screen.visibleFrame
        for (center, size, radius) in [(CGPoint(x: frame.midX, y: frame.midY), CGSize(width: 60, height: 40), 1.0),
                                       (CGPoint(x: frame.minX + 50, y: frame.maxY - 50), CGSize(width: 60, height: 40), 1.0),
                                       (CGPoint(x: frame.midX, y: frame.midY), CGSize(width: 400, height: 20), 1.0),
                                       (CGPoint(x: frame.midX, y: frame.midY), CGSize(width: 600, height: 400), 0.1)] {
            for depth in [false, true] {
                settings = RulerSettings(); settings!.kind = .perspectiveEllipse; settings!.enabled = true
                settings!.circleRadius = radius
                let x = center.x - size.width / 2, y = top - center.y - size.height / 2
                settings!.corners = [RulerPoint(x: x, y: y), RulerPoint(x: x + size.width, y: y),
                                     RulerPoint(x: x + size.width, y: y + size.height), RulerPoint(x: x, y: y + size.height)]
                settings!.enableDepth(depth)
                if depth { settings!.depthSettings.offset = 80 }
                let original = settings!
                overlay.setEditing(true) { [weak self] in self?.settings = $0 }
                checkSymbols()
                let panels = NSApp.windows.filter { $0.title.hasPrefix("Ruler handle") && $0.isVisible }
                let sections = [(settings!.sectionCorners, settings!.sectionRadius), (settings!.corners, settings!.circleRadius)]
                let guides = sections.map { corners, radius in
                    RulerGeometry.projectedCircle(corners, radius: radius)!.reduce(CGRect.null) { rect, point in
                        rect.union(CGRect(origin: CGPoint(x: point.x, y: top - point.y), size: .zero))
                    }
                }
                for panel in panels {
                    assert(guides.allSatisfy { !panel.frame.intersects($0.insetBy(dx: -4, dy: -4)) }, "Compact ellipse is obscured by \(panel.title)")
                    assert(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) }, "Handle must stay on a usable display")
                }
                for i in panels.indices {
                    for j in panels.indices where j > i {
                        assert(hypot(panels[i].frame.midX - panels[j].frame.midX, panels[i].frame.midY - panels[j].frame.midY) >= 36)
                    }
                }
                assert(settings == original, "Proxy layout must not change ruler geometry")
                overlay.updateDrag(.move, delta: CGPoint(x: 15, y: 10), finished: true)
                let corner = original.sectionCorners[0]
                assert(hypot(settings!.corners[0].x - corner.x - 15, settings!.corners[0].y - corner.y - 10) < 1e-7, "External move handle must preserve drag distance")
                overlay.setEditing(false) { _ in }
            }
        }
        print("Compact ellipse handles: small/thin guides stay clear, depth controls remain separated/on-screen, edge placement and proxy drag geometry passed.")
    }
    func checkKeyboardEditing() {
        settings = RulerSettings(); settings!.kind = .isometric; settings!.enabled = true
        var contact = false
        overlay.isContact = { contact }
        assert(!overlay.keyboardEvent(key: 124, flags: .maskControl, down: true, ownApp: false))
        overlay.setEditing(true) { [weak self] in self?.settings = $0 }
        let entry = settings!
        for flags: CGEventFlags in [.maskControl, [.maskControl, .maskAlternate], [.maskControl, .maskShift]] {
            assert(overlay.keyboardEvent(key: 124, flags: flags, down: true, ownApp: false))
        }
        assert(settings == entry, "Keyboard callback must not write settings synchronously")
        overlay.flushKeyboardEdit()
        assert(abs(settings!.centerX - entry.centerX - 11.1) < 1e-8)
        assert(overlay.keyboardEvent(key: 124, flags: [], down: false, ownApp: true), "Captured key-up must stay consumed after focus/Control changes")
        assert(!overlay.keyboardEvent(key: 123, flags: .maskControl, down: true, ownApp: true), "Driver fields must retain their keyboard input")
        assert(!overlay.keyboardEvent(key: 123, flags: [.maskControl, .maskCommand], down: true, ownApp: false))
        assert(!overlay.keyboardEvent(key: 0, flags: .maskControl, down: true, ownApp: false))
        contact = true
        assert(!overlay.keyboardEvent(key: 123, flags: .maskControl, down: true, ownApp: false))
        contact = false
        assert(overlay.keyboardEvent(key: 51, flags: .maskControl, down: true, ownApp: false))
        overlay.flushKeyboardEdit(); assert(settings == entry)
        assert(overlay.keyboardEvent(key: 51, flags: [], down: false, ownApp: false))
        let pointer = CGPoint(x: 300, y: 250)
        assert(overlay.keyboardEvent(key: 115, flags: .maskControl, down: true, ownApp: false, pointer: pointer))
        overlay.flushKeyboardEdit()
        assert(hypot(settings!.editingCenter.x - pointer.x, settings!.editingCenter.y - pointer.y) < 1e-8)
        assert(overlay.keyboardEvent(key: 115, flags: [], down: false, ownApp: false))
        let centered = settings!
        assert(overlay.keyboardEvent(key: 125, flags: .maskControl, down: true, ownApp: false))
        overlay.setEditing(false) { _ in assertionFailure("Pending key edit survived exit") }
        overlay.flushKeyboardEdit(); assert(settings == centered)
        assert(overlay.keyboardEvent(key: 125, flags: [], down: false, ownApp: false))
        assert(!overlay.keyboardEvent(key: 125, flags: [], down: true, ownApp: false))
        print("Ruler keyboard: coalesced 0.1/1/10-point moves, entry reset, cursor recenter, focus/contact/modifier gates, captured key-up and pending-edit cancellation passed. No events posted.")
    }
}
