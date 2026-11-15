#if APP
import AppKit
import QuartzCore

// Visual previews belong to the UI owner. Only validated gesture-end values
// cross the settings boundary; no preview geometry enters HID processing.
@MainActor
final class RulerOverlay {
    private var panels: [NSPanel] = []
    private var canvasBars: [NSPanel] = []
    private var controlBounds: [CGRect] = []
    var onToggleEditing: (() -> Void)?
    var onSelectKind: ((RulerKind) -> Void)?
    var onControlBoundsChanged: (([CGRect]) -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    private var handles: [RulerHandleID: NSPanel] = [:]
    private var editing = false
    private var modifierEditing = false
    var isContact: (() -> Bool)?
    var selectedFamily: (() -> Int?)?
    private var activeFamily: Int?
    var contactAnchor: (() -> CGPoint)?
    private var guideAnchor: CGPoint?
    private var strokeAnchor: CGPoint?
    private var edited: ((RulerSettings) -> Void)?
    private var timer: Timer?
    private var provider: (() -> RulerSettings?)?
    private var previous: RulerSettings?
    private var frames: [CGRect] = []
    private var top: CGFloat = 0
    private var dragBase: RulerSettings?
    private var activeHandle: RulerHandleID?
    private var dragOrigin = CGPoint.zero
    private var preview: RulerSettings?
    private var previewDirty = false

    func setEditing(_ value: Bool, onChange: @escaping (RulerSettings) -> Void) {
        cancelDrag()
        editing = value; edited = onChange
        previous = nil
        update()
    }
    func start(provider: @escaping () -> RulerSettings?) {
        stop()
        self.provider = provider
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateModifier(NSEvent.modifierFlags.contains(.control))
                self.update()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    // Reuse the normal edit transition; never change routing in the middle of a stroke.
    func updateModifier(_ held: Bool) {
        guard held != modifierEditing, dragBase == nil, !(isContact?() ?? false) else { return }
        if held {
            guard !editing, provider?() != nil else { return }
            onToggleEditing?()
            modifierEditing = editing
        } else {
            modifierEditing = false
            if editing { onToggleEditing?() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil; provider = nil
        editing = false; modifierEditing = false; edited = nil
        guideAnchor = nil; strokeAnchor = nil
        cancelDrag()
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        hideHandles()
        canvasBars.forEach { $0.orderOut(nil) }; canvasBars.removeAll()
        publishControlBounds([])
        onMenuTracking?(false)
        previous = nil; frames = []
    }
    func refreshDisplayGeometry() {
        cancelDrag()
        frames = []; previous = nil
        update()
    }
    private func cancelDrag() {
        dragBase = nil; activeHandle = nil; preview = nil; previewDirty = false
    }
    private func hideHandles() {
        handles.values.forEach { $0.orderOut(nil) }; handles.removeAll()
    }
    private func update() {
        let settings = provider?()
        if let dragBase, settings == dragBase {
            if previewDirty, let preview {
                draw(preview)
                positionHandles(preview)
                previewDirty = false
            }
            return
        }
        if dragBase != nil { cancelDrag() }
        let cursor = NSEvent.mouseLocation
        let point = CGPoint(x: cursor.x, y: top - cursor.y)
        if isContact?() ?? false { strokeAnchor = contactAnchor?() ?? strokeAnchor ?? point }
        else { strokeAnchor = nil }
        let anchor = editing ? settings?.editingCenter : (strokeAnchor ?? point)
        let follows = settings?.kind == .isometric || settings?.kind == .perspective
        let selected = editing ? nil : selectedFamily?()
        let moved = (follows && anchor != guideAnchor) || selected != activeFamily
        activeFamily = selected
        guideAnchor = anchor
        if moved, settings == previous, let settings, !frames.isEmpty { draw(settings); return }
        guard settings != previous || (frames.isEmpty && settings != nil) else { return }
        previous = settings
        hideHandles()
        guard let settings, (try? settings.validate()) != nil else {
            panels.forEach { $0.orderOut(nil) }
            canvasBars.forEach { $0.orderOut(nil) }
            publishControlBounds([])
            return
        }
        if frames.isEmpty {
            panels.forEach { $0.orderOut(nil) }; panels.removeAll()
            canvasBars.forEach { $0.orderOut(nil) }; canvasBars.removeAll()
            frames = NSScreen.screens.map(\.frame)
            top = frames.first?.maxY ?? 0
            for frame in frames {
                let panel = GuidePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                configure(panel, title: "Ruler guide", clickThrough: true)
                panel.contentView = RulerGuideView(frame: CGRect(origin: .zero, size: frame.size))
                panels.append(panel)
            }
        }
        draw(settings)
        updateCanvasBars(settings)
        if editing { addHandles(settings) }
    }
    private func publishControlBounds(_ bounds: [CGRect]) {
        guard bounds != controlBounds else { return }
        controlBounds = bounds
        onControlBoundsChanged?(bounds)
    }
    private func updateCanvasBars(_ settings: RulerSettings) {
        if canvasBars.isEmpty {
            for frame in frames {
                let panel = GuidePanel(contentRect: CGRect(x: frame.maxX - 312, y: frame.maxY - 82, width: 296, height: 40),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                configure(panel, title: "Ruler canvas controls", clickThrough: false)
                let bar = RulerCanvasControls(frame: CGRect(x: 0, y: 0, width: 296, height: 40))
                bar.toggle = { [weak self] in self?.onToggleEditing?() }
                bar.select = { [weak self] kind in
                    self?.onSelectKind?(kind)
                    self?.previous = nil
                    self?.update()
                }
                bar.menuTracking = { [weak self] in self?.onMenuTracking?($0) }
                panel.contentView = bar
                canvasBars.append(panel)
            }
        }
        for panel in canvasBars {
            (panel.contentView as? RulerCanvasControls)?.update(kind: settings.kind, editing: editing)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        publishControlBounds(canvasBars.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) })
    }
    private func configure(_ panel: NSPanel, title: String, clickThrough: Bool) {
        panel.title = title
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.ignoresMouseEvents = clickThrough; panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
    }
    private func draw(_ settings: RulerSettings) {
        for (panel, frame) in zip(panels, frames) {
            (panel.contentView as? RulerGuideView)?.render(settings, screen: frame, top: top, anchor: guideAnchor ?? settings.center, activeFamily: activeFamily)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
    private func visiblePoint(_ point: CGPoint) -> CGPoint? {
        let native = CGPoint(x: point.x, y: top - point.y)
        return frames.map { frame in
            CGPoint(x: min(frame.maxX - 22, max(frame.minX + 22, native.x)),
                    y: min(frame.maxY - 22, max(frame.minY + 22, native.y)))
        }.min { hypot($0.x - native.x, $0.y - native.y) < hypot($1.x - native.x, $1.y - native.y) }
    }
    private func handlePositions(_ settings: RulerSettings) -> [RulerHandleID: CGPoint] {
        var result: [RulerHandleID: CGPoint] = [:]
        for handle in settings.editHandles {
            guard let base = visiblePoint(handle.point) else { continue }
            var candidates = [base]
            for step in 1...8 {
                let distance = Double(step) * 38
                candidates += [CGPoint(x: base.x + distance, y: base.y), CGPoint(x: base.x - distance, y: base.y),
                               CGPoint(x: base.x, y: base.y + distance), CGPoint(x: base.x, y: base.y - distance)]
            }
            result[handle.id] = candidates.first { candidate in
                frames.contains { $0.insetBy(dx: 20, dy: 20).contains(candidate) } &&
                result.values.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) >= 36 }
            } ?? base
        }
        return result
    }
    private func positionHandles(_ settings: RulerSettings) {
        for (id, point) in handlePositions(settings) where id != activeHandle {
            handles[id]?.setFrameOrigin(CGPoint(x: point.x - 16, y: point.y - 16))
        }
    }
    private func addHandles(_ settings: RulerSettings) {
        let positions = handlePositions(settings)
        for handle in settings.editHandles {
            guard let point = positions[handle.id] else { continue }
            let panel = GuidePanel(contentRect: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            configure(panel, title: "Ruler handle · \(handle.id.title)", clickThrough: false)
            let view = RulerHandle(frame: CGRect(x: 0, y: 0, width: 32, height: 32), role: handle.id)
            view.changed = { [weak self] delta, finished in self?.updateDrag(handle.id, delta: delta, finished: finished) }
            panel.contentView = view
            panel.orderFrontRegardless(); handles[handle.id] = panel
        }
    }
    // Shared gesture entry point also allows deterministic native preview checks
    // without synthesizing mouse events or touching a painting application's data.
    func updateDrag(_ handle: RulerHandleID, delta: CGPoint, finished: Bool) {
        guard editing, let baseline = dragBase ?? previous, handles[handle] != nil else { return }
        if dragBase == nil {
            dragBase = baseline; activeHandle = handle
            dragOrigin = handles[handle]!.frame.origin
        }
        guard activeHandle == handle else { return }
        let candidate = baseline.editing(handle, delta: delta)
        if finished {
            cancelDrag()
            if let candidate { edited?(candidate) }
            previous = nil
            update()
        } else if let candidate {
            preview = candidate; previewDirty = true
            handles[handle]?.setFrameOrigin(CGPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y - delta.y))
        }
    }
}

@MainActor
private final class RulerCanvasControls: NSView, NSMenuDelegate {
    var toggle: (() -> Void)?
    var select: ((RulerKind) -> Void)?
    var menuTracking: ((Bool) -> Void)?
    private let kind = NSPopUpButton(frame: CGRect(x: 8, y: 8, width: 190, height: 24), pullsDown: false)
    private let edit = NSButton(frame: CGRect(x: 206, y: 8, width: 82, height: 24))
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 8
        kind.addItems(withTitles: RulerKind.allCases.map(\.title))
        kind.menu?.delegate = self
        kind.target = self; kind.action = #selector(selectKind)
        kind.setAccessibilityLabel("Canvas ruler type")
        kind.toolTip = "Choose ruler on canvas"
        edit.bezelStyle = .rounded
        edit.target = self; edit.action = #selector(toggleEditing)
        addSubview(kind); addSubview(edit)
    }
    required init?(coder: NSCoder) { nil }
    func update(kind value: RulerKind, editing: Bool) {
        kind.selectItem(at: RulerKind.allCases.firstIndex(of: value)!)
        edit.title = editing ? "Done" : "Edit ruler"
        edit.setAccessibilityLabel(editing ? "Finish ruler editing on canvas" : "Edit ruler on canvas")
        edit.toolTip = editing ? "Return to drawing" : "Show ruler handles"
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { menuTracking?(false) }
    @objc private func toggleEditing() { toggle?() }
    @objc private func selectKind() {
        guard RulerKind.allCases.indices.contains(kind.indexOfSelectedItem) else { return }
        select?(RulerKind.allCases[kind.indexOfSelectedItem])
    }
}

@MainActor
private final class RulerGuideView: NSView {
    private var shapes: [CAShapeLayer] = []
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    func render(_ settings: RulerSettings, screen: CGRect, top: CGFloat, anchor: CGPoint, activeFamily: Int?) {
        var paths: [CGMutablePath] = []
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.minX, y: top - p.y - screen.minY) }
        func ray(_ path: CGMutablePath, _ origin: CGPoint, _ direction: CGPoint) {
            let norm = hypot(direction.x, direction.y)
            guard norm > 1e-9 else { return }
            let dx = direction.x / norm * 300000, dy = direction.y / norm * 300000
            path.move(to: local(CGPoint(x: origin.x - dx, y: origin.y - dy)))
            path.addLine(to: local(CGPoint(x: origin.x + dx, y: origin.y + dy)))
        }
        switch settings.kind {
        case .radial:
            let path = CGMutablePath()
            for i in 0..<Int(ceil(180 / settings.spacing)) { ray(path, settings.center, RulerGeometry.direction(settings.angle + Double(i) * settings.spacing)) }
            paths = [path]
        case .isometric, .perspective:
            paths = RulerGeometry.directions(settings, anchor: anchor).enumerated().map { family, direction in
                let path = CGMutablePath()
                ray(path, anchor, direction)
                let norm = hypot(direction.x, direction.y)
                if norm > 1e-6 {
                    for tick in RulerGeometry.ticks(settings, anchor: anchor, family: family) {
                        let length = tick.major ? 4.0 : 2.0
                        path.move(to: local(CGPoint(x: tick.point.x - direction.y / norm * length, y: tick.point.y + direction.x / norm * length)))
                        path.addLine(to: local(CGPoint(x: tick.point.x + direction.y / norm * length, y: tick.point.y - direction.x / norm * length)))
                    }
                }
                return path
            }
        case .vanishing:
            paths = settings.vanishingPoints.map { point in
                let path = CGMutablePath()
                for i in 0..<12 { ray(path, point.cg, RulerGeometry.direction(Double(i) * 15)) }
                return path
            }
        case .perspectiveEllipse:
            let ellipse = CGMutablePath(), rectangle = CGMutablePath()
            if let curve = RulerGeometry.projectedCircle(settings.corners) { ellipse.addLines(between: curve.map(local)) }
            rectangle.addLines(between: settings.corners.map { local($0.cg) }); rectangle.closeSubpath()
            paths = [ellipse, rectangle]
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if shapes.count != paths.count * 2 {
            shapes.forEach { $0.removeFromSuperlayer() }; shapes = []
            let colors: [NSColor] = [.cyan, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemBlue]
            for index in paths.indices {
                for (width, color) in [(1.25, NSColor.black), (0.5, colors[index % colors.count])] {
                    let shape = CAShapeLayer()
                    shape.fillColor = nil; shape.strokeColor = color.cgColor; shape.lineWidth = width
                    layer?.addSublayer(shape); shapes.append(shape)
                }
            }
        }
        for (index, shape) in shapes.enumerated() {
            let active = index / 2 == activeFamily
            shape.path = paths[index / 2]
            shape.opacity = active ? Float(max(0.65, settings.opacity)) : Float(settings.opacity) * 0.65
            shape.lineWidth = index % 2 == 0 ? (active ? 2.25 : 1.25) : (active ? 1.25 : 0.5)
        }
        CATransaction.commit()
    }
}

private extension RulerHandleID {
    var title: String {
        switch self {
        case .move: "Move ruler"
        case .rotate: "Rotate ruler"
        case .size: "Resize ruler"
        case .axis: "Adjust axis angle"
        case .viewTilt: "Camera view tilt"
        case .fieldOfView: "Camera field of view"
        case .tickDistance: "Tick spacing"
        case .corner(let i): "Corner \(i + 1)"
        case .edge(let i): "Edge \(i + 1)"
        case .vanishing(let i): "Vanishing point \(i + 1)"
        }
    }
    var symbol: String {
        switch self {
        case .move: "✥"
        case .rotate: "↻"
        case .size: "⤢"
        case .axis: "∠"
        case .viewTilt: "↕"
        case .fieldOfView: "FOV"
        case .tickDistance: "⊣"
        case .corner(let i), .vanishing(let i): String(i + 1)
        case .edge: "◇"
        }
    }
}

@MainActor
private final class RulerHandle: NSView {
    var changed: ((CGPoint, Bool) -> Void)?
    private let role: RulerHandleID
    private var start = CGPoint.zero
    private var tracking: NSTrackingArea?
    init(frame: CGRect, role: RulerHandleID) {
        self.role = role
        super.init(frame: frame)
        setAccessibilityLabel(role.title)
        toolTip = role.title
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = role == .move || role == .rotate ? 16 : 6
        let label = NSTextField(labelWithString: role.symbol)
        label.frame = CGRect(x: 0, y: 6, width: 32, height: 20)
        label.alignment = .center; label.textColor = .white
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.controlAccentColor.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor }
    override func resetCursorRects() { addCursorRect(bounds, cursor: role == .move ? .openHand : .crosshair) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; if role == .move { NSCursor.closedHand.set() }; changed?(.zero, false) }
    override func mouseDragged(with event: NSEvent) { move(finished: false) }
    override func mouseUp(with event: NSEvent) { move(finished: true) }
    private func move(finished: Bool) {
        let point = NSEvent.mouseLocation
        changed?(CGPoint(x: point.x - start.x, y: start.y - point.y), finished)
    }
}
#endif
