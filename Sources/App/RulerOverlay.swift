#if APP
import AppKit
import QuartzCore
import ApplicationServices

// Visual previews belong to the UI owner. Only validated gesture-end values
// cross the settings boundary; no preview geometry enters HID processing.
@MainActor
final class RulerOverlay {
    private var panels: [NSPanel] = []
    private var referenceOrigin: CGPoint?
    var onToggleEditing: (() -> Void)?
    var onTogglePicker: (() -> Void)?
    var pickerShortcut: (() -> CustomKeyShortcut?)?
    let picker = RulerPicker()
    private var pickerFinished: ((RulerPickerAction?) -> Void)?
    private var pickerOpening = false
    private var pickerButtons = Set<CGMouseButton>()
    private var pickerMouseCaptured: Bool { !pickerButtons.isEmpty }
    private var pickerTop: CGFloat = 0
    private var keyboardMask: CGEventMask = 0
    var pickerVisible: Bool { picker.isVisible }
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
    private var handleFrames: [CGRect] = []
    private var top: CGFloat = 0
    private var dragBase: RulerSettings?
    private var activeHandle: RulerHandleID?
    private var dragOrigin = CGPoint.zero
    private var preview: RulerSettings?
    private var previewDirty = false
    private var editingEntry: RulerSettings?
    private var keyboardPreview: RulerSettings?
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var capturedKeys = Set<CGKeyCode>()
    private var editGeneration = 0
    isolated deinit { stop() }
    var keyboardStatus: String {
        if keyboardTap != nil { return "Keyboard editing ready over other apps." }
        return AXIsProcessTrusted() ? "Keyboard editing unavailable in this session; use the handles or numeric fields." : "Keyboard editing needs Accessibility permission in System Settings."
    }

    // Main-run-loop callback only. File writes/commits are coalesced outside it.
    private static let keyboardCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let overlay = Unmanaged<RulerOverlay>.fromOpaque(info).takeUnretainedValue()
        let key = CGKeyCode(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let point = event.location
        let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let consumed = MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout {
                if let tap = overlay.keyboardTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return false
            }
            if type != .keyDown && type != .keyUp {
                return overlay.pickerPointer(type: type, point: point)
            }
            let ownApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            return overlay.keyboardEvent(key: key, flags: CGEventFlags(rawValue: flags), down: type == .keyDown, ownApp: ownApp, repeatKey: repeatKey, pointer: point)
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
    private func updateKeyboardTap() {
        guard editing || pickerOpening || picker.isVisible || pickerMouseCaptured || !capturedKeys.isEmpty || pickerShortcut?() != nil else { removeKeyboardTap(); return }
        var mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        if pickerOpening || picker.isVisible || pickerMouseCaptured {
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged] {
                mask |= CGEventMask(1) << type.rawValue
            }
        }
        guard keyboardTap == nil || keyboardMask != mask else { return }
        removeKeyboardTap()
        guard AXIsProcessTrusted() else { return }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.keyboardCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        keyboardTap = tap; keyboardSource = source; keyboardMask = mask
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func removeKeyboardTap() {
        if let keyboardSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardSource, .commonModes) }
        if let keyboardTap { CFMachPortInvalidate(keyboardTap) }
        keyboardTap = nil; keyboardSource = nil; keyboardMask = 0
    }
    // Same entry point is exercised without posting events by the native harness.
    @discardableResult
    func keyboardEvent(key: CGKeyCode, flags: CGEventFlags, down: Bool, ownApp: Bool, repeatKey: Bool = false, pointer: CGPoint? = nil) -> Bool {
        if !down {
            guard capturedKeys.remove(key) != nil else { return false }
            DispatchQueue.main.async { [weak self] in self?.updateKeyboardTap() }
            return true
        }
        let shortcut = pickerShortcut?()
        let matchesPicker = shortcut.map { $0.keyCode == key && $0.modifiers == flags.intersection(CGEventFlags(rawValue: CustomKeyShortcut.allowedModifiers)).rawValue } ?? false
        if picker.isVisible {
            if matchesPicker {
                capturedKeys.insert(key)
                if !repeatKey { DispatchQueue.main.async { [weak self] in self?.finishPicker(nil) } }
                return true
            }
            let choice: RulerPickerAction?
            switch key {
            case 123, 126: picker.navigate(-1); capturedKeys.insert(key); return true
            case 124, 125: picker.navigate(1); capturedKeys.insert(key); return true
            case 48: picker.navigate(flags.contains(.maskShift) ? -1 : 1); capturedKeys.insert(key); return true
            case 53: choice = nil
            case 36, 76: choice = picker.choice
            case 5: choice = .toggleRuler
            case 18, 19, 20, 21, 23, 22, 26, 28, 25: choice = picker.directChoice([18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: key)!)
            default:
                DispatchQueue.main.async { [weak self] in self?.finishPicker(nil) }
                return false
            }
            capturedKeys.insert(key)
            guard choice == nil || !pickerMouseCaptured && !(isContact?() ?? false) else { return true }
            DispatchQueue.main.async { [weak self] in self?.finishPicker(choice) }
            return true
        }
        if matchesPicker, !ownApp {
            let firstPress = capturedKeys.insert(key).inserted
            if firstPress, !repeatKey { DispatchQueue.main.async { [weak self] in self?.onTogglePicker?() } }
            return true
        }
        // Once captured, keep suppressing repeats until key-up, even after Control release.
        if capturedKeys.contains(key), (!editing || !flags.contains(.maskControl)) { return true }
        guard editing, dragBase == nil, !(isContact?() ?? false), !ownApp,
              flags.contains(.maskControl), !flags.contains(.maskCommand),
              let current = keyboardPreview ?? provider?(), let entry = editingEntry else { return capturedKeys.contains(key) }
        let step = flags.contains(.maskAlternate) ? 0.1 : (flags.contains(.maskShift) ? 10.0 : 1.0)
        let candidate: RulerSettings?
        switch key {
        case 123: candidate = current.editing(.move, delta: CGPoint(x: -step, y: 0), screenSpace: true)
        case 124: candidate = current.editing(.move, delta: CGPoint(x: step, y: 0), screenSpace: true)
        case 125: candidate = current.editing(.move, delta: CGPoint(x: 0, y: step), screenSpace: true)
        case 126: candidate = current.editing(.move, delta: CGPoint(x: 0, y: -step), screenSpace: true)
        case 115:
            let cursor = NSEvent.mouseLocation, center = current.editingCenter
            let point = pointer ?? CGPoint(x: cursor.x, y: top - cursor.y)
            candidate = current.editing(.move, delta: CGPoint(x: point.x - center.x, y: point.y - center.y), screenSpace: true)
        case 51: candidate = entry
        default: return false
        }
        capturedKeys.insert(key)
        guard let candidate else { return true } // Invalid movement must not become a painting-app shortcut.
        let schedule = keyboardPreview == nil
        keyboardPreview = candidate
        if schedule {
            let generation = editGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editGeneration == generation else { return }
                self.flushKeyboardEdit()
            }
        }
        return true
    }
    @discardableResult
    func presentPicker(current: RulerKind, rulerEnabled: Bool, finished: @escaping (RulerPickerAction?) -> Void) -> Bool {
        guard !editing, !(isContact?() ?? false), !pickerMouseCaptured else { return false }
        pickerOpening = true
        updateKeyboardTap()
        guard keyboardTap != nil else { pickerOpening = false; updateKeyboardTap(); return false }
        let screens = NSScreen.screens
        pickerTop = screens.first?.frame.maxY ?? 0
        guard picker.present(current: current, rulerEnabled: rulerEnabled, anchor: NSEvent.mouseLocation, screens: screens.map(\.visibleFrame),
            onChoose: { [weak self] kind in self?.finishPicker(kind) }) else {
            pickerOpening = false; updateKeyboardTap(); return false
        }
        pickerOpening = false
        updateKeyboardTap()
        pickerFinished = finished
        return true
    }
    func finishPicker(_ kind: RulerPickerAction?) {
        guard picker.isVisible else { return }
        picker.dismiss()
        let callback = pickerFinished; pickerFinished = nil
        updateKeyboardTap()
        callback?(kind)
    }
    @discardableResult
    func pickerPointer(type: CGEventType, point: CGPoint) -> Bool {
        let native = CGPoint(x: point.x, y: pickerTop - point.y)
        switch type {
        case .mouseMoved:
            if picker.isVisible { picker.hover(at: native) }
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard pickerOpening || picker.isVisible || pickerMouseCaptured else { return false }
            pickerButtons.insert(type == .leftMouseDown ? .left : (type == .rightMouseDown ? .right : .center))
            picker.hover(at: native)
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if picker.isVisible { picker.hover(at: native) }
            return pickerMouseCaptured
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button: CGMouseButton = type == .leftMouseUp ? .left : (type == .rightMouseUp ? .right : .center)
            guard pickerButtons.remove(button) != nil else { return false }
            guard pickerButtons.isEmpty else { return true }
            let choice = picker.layout?.hit(native).flatMap { picker.directChoice($0) }
            DispatchQueue.main.async { [weak self] in self?.finishPicker(choice); self?.updateKeyboardTap() }
            return true
        default: return false
        }
    }
    func flushKeyboardEdit() {
        defer { keyboardPreview = nil }
        guard editing, dragBase == nil, !(isContact?() ?? false), let candidate = keyboardPreview else { return }
        edited?(candidate)
        previous = nil
        update()
    }

    func setEditing(_ value: Bool, onChange: @escaping (RulerSettings) -> Void) {
        cancelDrag()
        editGeneration += 1; keyboardPreview = nil
        editingEntry = value ? provider?() : nil
        if value {
            let cursor = NSEvent.mouseLocation
            referenceOrigin = CGPoint(x: cursor.x, y: top - cursor.y)
        }
        editing = value; edited = onChange
        updateKeyboardTap()
        previous = nil
        update()
    }
    func start(provider: @escaping () -> RulerSettings?) {
        stop()
        self.provider = provider
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateKeyboardTap()
                self.updateModifier(NSEvent.modifierFlags.contains(.control))
                self.update()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    // Reuse the normal edit transition; never change routing in the middle of a stroke.
    func updateModifier(_ held: Bool) {
        guard !picker.isVisible, held != modifierEditing, dragBase == nil, !(isContact?() ?? false) else { return }
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
        picker.dismiss(); pickerOpening = false; pickerFinished = nil; pickerButtons.removeAll()
        editing = false; modifierEditing = false; edited = nil
        editGeneration += 1; keyboardPreview = nil; editingEntry = nil; capturedKeys.removeAll(); removeKeyboardTap()
        guideAnchor = nil; strokeAnchor = nil; referenceOrigin = nil
        cancelDrag()
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        hideHandles()
        previous = nil; frames = []
    }
    func refreshDisplayGeometry() {
        finishPicker(nil)
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
        let follows = settings?.kind == .isometric || settings?.kind == .perspective || settings?.kind == .vanishing || (settings?.kind == .perspectiveEllipse && settings?.ellipseSizing != .fixed) || (settings?.kind == .radial && settings?.radialSettings.locked == false)
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
            return
        }
        if frames.isEmpty {
            panels.forEach { $0.orderOut(nil) }; panels.removeAll()
            let screens = NSScreen.screens
            frames = screens.map(\.frame)
            handleFrames = screens.map(\.visibleFrame)
            top = frames.first?.maxY ?? 0
            for frame in frames {
                let panel = GuidePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
                configure(panel, title: "Ruler guide", clickThrough: true)
                panel.contentView = RulerGuideView(frame: CGRect(origin: .zero, size: frame.size))
                panels.append(panel)
            }
        }
        draw(settings)
        if editing { addHandles(settings) }
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
            (panel.contentView as? RulerGuideView)?.render(settings, screen: frame, top: top, anchor: editing ? settings.editingCenter : (guideAnchor ?? settings.center), activeFamily: activeFamily, editing: editing)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
    private func visiblePoint(_ point: CGPoint) -> CGPoint? {
        let native = CGPoint(x: point.x, y: top - point.y)
        return handleFrames.map { frame in
            CGPoint(x: min(frame.maxX - 22, max(frame.minX + 22, native.x)),
                    y: min(frame.maxY - 22, max(frame.minY + 22, native.y)))
        }.min { hypot($0.x - native.x, $0.y - native.y) < hypot($1.x - native.x, $1.y - native.y) }
    }
    private func handlePositions(_ settings: RulerSettings) -> [RulerHandleID: CGPoint] {
        var result: [RulerHandleID: CGPoint] = [:]
        var clearAreas: [CGRect] = []
        if settings.kind == .ellipse {
            let bounds = RulerGeometry.ordinaryEllipse(settings).reduce(CGRect.null) { rect, point in
                rect.union(CGRect(origin: CGPoint(x: point.x, y: top - point.y), size: .zero))
            }
            if min(bounds.width, bounds.height) <= 240 { clearAreas.append(bounds.insetBy(dx: -24, dy: -24)) }
        }
        if settings.kind == .perspectiveEllipse {
            var sections = [(settings.sectionCorners, settings.sectionRadius)]
            if settings.depthSettings.enabled { sections.append((settings.corners, settings.circleRadius)) }
            for (corners, radius) in sections {
                guard let curve = RulerGeometry.projectedCircle(corners, radius: radius) else { continue }
                let bounds = curve.reduce(CGRect.null) { rect, point in
                    rect.union(CGRect(origin: CGPoint(x: point.x, y: top - point.y), size: .zero))
                }
                // Keep the actual circle visible even when its construction quad is large.
                if min(bounds.width, bounds.height) <= 240 { clearAreas.append(bounds.insetBy(dx: -24, dy: -24)) }
            }
        }
        for handle in settings.editHandles {
            let point = handle.id == .reference && settings.fixedReference == nil ? referenceOrigin.map { CGPoint(x: $0.x + 40, y: $0.y + 40) } ?? handle.point : handle.point
            guard let base = visiblePoint(point) else { continue }
            var candidates = [base]
            for step in 1...16 {
                let distance = Double(step) * 38
                candidates += [CGPoint(x: base.x + distance, y: base.y), CGPoint(x: base.x - distance, y: base.y),
                               CGPoint(x: base.x, y: base.y + distance), CGPoint(x: base.x, y: base.y - distance),
                               CGPoint(x: base.x + distance, y: base.y + distance), CGPoint(x: base.x - distance, y: base.y + distance),
                               CGPoint(x: base.x + distance, y: base.y - distance), CGPoint(x: base.x - distance, y: base.y - distance)]
            }
            result[handle.id] = candidates.first { candidate in
                handleFrames.contains { $0.insetBy(dx: 20, dy: 20).contains(candidate) } &&
                !clearAreas.contains { $0.contains(candidate) } &&
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
            let view = RulerHandle(frame: CGRect(x: 0, y: 0, width: 32, height: 32), role: handle.id, settings: settings)
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
        let candidate = baseline.editing(handle, delta: delta, screenSpace: NSEvent.modifierFlags.contains(.option), referenceOrigin: referenceOrigin, snap: NSEvent.modifierFlags.contains(.shift))
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

extension RulerSettings {
    func guideNSColor(at index: Int) -> NSColor {
        if let color = guideColor(at: index) {
            return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        }
        let defaults: [NSColor] = [.cyan, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemBlue]
        return defaults[index % defaults.count]
    }
}

@MainActor
private final class RulerGuideView: NSView {
    private var shapes: [CAShapeLayer] = []
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    func render(_ settings: RulerSettings, screen: CGRect, top: CGFloat, anchor: CGPoint, activeFamily: Int?, editing: Bool) {
        var paths: [CGMutablePath] = []
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.minX, y: top - p.y - screen.minY) }
        func ray(_ path: CGMutablePath, _ origin: CGPoint, _ direction: CGPoint) {
            let norm = hypot(direction.x, direction.y)
            guard norm > 1e-9 else { return }
            let dx = direction.x / norm * 300000, dy = direction.y / norm * 300000
            path.move(to: local(CGPoint(x: origin.x - dx, y: origin.y - dy)))
            path.addLine(to: local(CGPoint(x: origin.x + dx, y: origin.y + dy)))
        }
        func measurements(_ path: CGMutablePath, family: Int, anchor: CGPoint, reference: Bool) {
            let direction = RulerGeometry.directions(settings, anchor: anchor)[family]
            if reference {
                ray(path, anchor, direction)
                if family == 0 { let point = local(anchor); path.addEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)) }
            }
            let norm = hypot(direction.x, direction.y)
            guard norm > 1e-6 else { return }
            for tick in RulerGeometry.ticks(settings, anchor: anchor, family: family) {
                let length = tick.major ? 4.0 : 2.0
                path.move(to: local(CGPoint(x: tick.point.x - direction.y / norm * length, y: tick.point.y + direction.x / norm * length)))
                path.addLine(to: local(CGPoint(x: tick.point.x + direction.y / norm * length, y: tick.point.y - direction.x / norm * length)))
            }
        }
        switch settings.kind {
        case .straight, .parallel, .connected, .ellipse:
            let path = CGMutablePath(), companion = CGMutablePath(), c = settings.constructionSettings
            let direction = RulerGeometry.direction(settings.angle)
            if settings.kind == .ellipse {
                let scale = editing ? 1 : RulerGeometry.constructionScale(settings, through: anchor)
                path.addLines(between: RulerGeometry.ordinaryEllipse(settings, scale: scale).map(local))
                if c.radial {
                    ray(companion, settings.center, CGPoint(x: anchor.x - settings.centerX, y: anchor.y - settings.centerY))
                }
            } else if settings.kind == .straight {
                if c.bounded { path.addLines(between: [local(c.start.cg), local(c.end.cg)]) }
                else { ray(path, c.start.cg, CGPoint(x: c.end.x - c.start.x, y: c.end.y - c.start.y)) }
            } else {
                let origin = settings.kind == .connected || c.fixed ? settings.center : anchor
                if settings.kind == .parallel && c.fixed {
                    for i in -20...20 {
                        let offset = Double(i) * c.spacing + c.offset
                        ray(path, CGPoint(x: origin.x - direction.y * offset, y: origin.y + direction.x * offset), direction)
                    }
                } else { ray(path, origin, direction) }
                let selectedOrigin = settings.kind == .parallel ? RulerGeometry.parallelOrigin(settings, through: anchor) : origin
                if settings.kind == .parallel && c.fixed { ray(companion, selectedOrigin, direction) }
                measurements(path, family: 0, anchor: selectedOrigin, reference: false)
            }
            paths = [path, companion]
        case .radial:
            let fan = CGMutablePath(), selected = CGMutablePath()
            let bend = settings.radialSettings.bend
            let extent = min(300000, max(2000, hypot(screen.midX - settings.centerX, top - screen.midY - settings.centerY) + hypot(screen.width, screen.height) * 2))
            func radial(_ path: CGMutablePath, _ direction: CGPoint) {
                if bend == 0 { ray(path, settings.center, direction) }
                else {
                    path.move(to: local(settings.center))
                    let control = CGPoint(x: settings.centerX + direction.x * extent / 2, y: settings.centerY + direction.y * extent / 2)
                    path.addQuadCurve(to: local(RulerGeometry.radialPoint(center: settings.center, direction: direction, bend: bend, parameter: extent)), control: local(control))
                }
            }
            let chosen = RulerGeometry.directions(settings, anchor: anchor).first!
            if settings.radialSettings.locked {
                let span = bend == 0 ? 180.0 : 360.0
                for i in 0..<Int(ceil(span / settings.spacing)) { radial(fan, RulerGeometry.direction(settings.angle + Double(i) * settings.spacing)) }
            } else { radial(fan, chosen) }
            if activeFamily != nil { radial(selected, chosen) }
            if settings.measureSettings.visible {
                let measure = settings.measureSettings
                for i in 1...(20 * measure.divisions) {
                    let t = Double(i) * measure.distance / Double(measure.divisions)
                    let point = RulerGeometry.radialPoint(center: settings.center, direction: chosen, bend: bend, parameter: t)
                    let dx = chosen.x - chosen.y * 2 * bend * t / 1000, dy = chosen.y + chosen.x * 2 * bend * t / 1000
                    let norm = hypot(dx, dy), length = i % measure.divisions == 0 ? 4.0 : 2.0
                    fan.move(to: local(CGPoint(x: point.x - dy / norm * length, y: point.y + dx / norm * length)))
                    fan.addLine(to: local(CGPoint(x: point.x + dy / norm * length, y: point.y - dx / norm * length)))
                }
            }
            paths = [fan, selected]
        case .isometric, .perspective, .vanishing:
            if settings.usesBox {
                let vertices = RulerGeometry.boxVertices(settings, anchor: anchor)
                paths = (0..<3).map { family in
                    let path = CGMutablePath()
                    if let vertices {
                        for edge in RulerGeometry.boxEdges where edge.family == family {
                            path.move(to: local(vertices[edge.from])); path.addLine(to: local(vertices[edge.to]))
                        }
                    }
                    if let reference = settings.fixedReference { measurements(path, family: family, anchor: reference.cg, reference: true) }
                    return path
                }
                break
            }
            paths = RulerGeometry.directions(settings, anchor: anchor).enumerated().map { family, direction in
                let path = CGMutablePath()
                ray(path, anchor, direction)
                if editing, let lines = settings.sceneLines, lines.indices.contains(family) {
                    for pair in [0, 2] {
                        path.move(to: local(lines[family][pair].cg))
                        path.addLine(to: local(lines[family][pair + 1].cg))
                    }
                }
                measurements(path, family: family, anchor: settings.fixedReference?.cg ?? anchor, reference: settings.fixedReference != nil)
                if family == 0, settings.showsHorizon, settings.kind == .vanishing || settings.camera == nil, let horizon = RulerGeometry.horizon(settings) {
                    ray(path, horizon.origin, horizon.direction)
                }
                return path
            }
        case .perspectiveEllipse:
            let ellipse = CGMutablePath(), rectangle = CGMutablePath()
            let radius = editing ? settings.sectionRadius : RulerGeometry.ellipseRadius(settings, through: anchor)
            if let curve = RulerGeometry.projectedCircle(settings.sectionCorners, radius: radius) { ellipse.addLines(between: curve.map(local)) }
            rectangle.addLines(between: settings.sectionCorners.map { local($0.cg) }); rectangle.closeSubpath()
            if editing, settings.showsPlaneGrid, let plane = RulerPlane(settings.sectionCorners) {
                for i in 1..<Int(ceil(1 / settings.planeStep)) {
                    let t = Double(i) * settings.planeStep
                    for (a, b) in [(CGPoint(x: t, y: 0), CGPoint(x: t, y: 1)), (CGPoint(x: 0, y: t), CGPoint(x: 1, y: t))] {
                        if let start = plane.screen(a), let end = plane.screen(b) {
                            rectangle.move(to: local(start)); rectangle.addLine(to: local(end))
                        }
                    }
                }
            }
            paths = [ellipse, rectangle]
            if settings.depthSettings.enabled {
                let depth = CGMutablePath()
                if settings.depthSettings.offset != 0 || radius != settings.circleRadius,
                   let reference = RulerGeometry.projectedCircle(settings.corners, radius: settings.circleRadius) {
                    depth.addLines(between: reference.map(local))
                }
                for (base, top) in settings.depthTangents(radius: radius) {
                    depth.move(to: local(base)); depth.addLine(to: local(top))
                }
                if editing {
                    if let lines = settings.depthSettings.sceneLines {
                        for pair in [0, 2] { depth.move(to: local(lines[pair].cg)); depth.addLine(to: local(lines[pair + 1].cg)) }
                    }
                    if let v = settings.depthSettings.direction {
                        let center = settings.editingCenter
                        ray(depth, center, CGPoint(x: v.x - center.x * v.z, y: v.y - center.y * v.z))
                    }
                }
                paths.append(depth)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if shapes.count != paths.count {
            shapes.forEach { $0.removeFromSuperlayer() }; shapes = []
            for _ in paths.indices {
                let shape = CAShapeLayer()
                shape.fillColor = nil
                layer?.addSublayer(shape); shapes.append(shape)
            }
        }
        for (index, shape) in shapes.enumerated() {
            let active = settings.kind == .radial ? (activeFamily != nil && index == 1) : (index == activeFamily)
            shape.path = paths[index]
            shape.strokeColor = settings.guideNSColor(at: index).cgColor
            shape.opacity = active ? Float(max(0.85, settings.opacity)) : Float(settings.opacity)
            shape.lineWidth = active ? 1.75 : 1
        }
        CATransaction.commit()
    }
}

private extension RulerHandleID {
    var title: String {
        switch self {
        case .chainReset: "Reset connected chain"
        case .parallelSpacing: "Parallel line spacing"
        case .constructionMode: "Cycle ellipse size mode"
        case .move: "Move ruler"
        case .rotate: "Rotate ruler"
        case .size: "Resize ruler"
        case .axis: "Adjust axis angle"
        case .isometricAxis(let i): "Isometric axis \(i + 1) angle"
        case .isometricPreset: "Cycle isometric presets"
        case .radialMode: "Toggle free or locked radial angles"
        case .radialBend: "Radial bend"
        case .radialSpacing: "Radial angular spacing"
        case .boxMode: "Toggle bounded box construction"
        case .boxLearn: "Toggle box dimension learning"
        case .boxSize(let i): "Box axis \(i + 1) extent"
        case .cameraAxis(let i): "Camera axis \(i + 1) · horizontal azimuth, vertical incline"
        case .cameraCircle: "Create perspective ellipse from camera plane"
        case .axisPolicy: "Toggle automatic axis changes"
        case .reference: "Pin measurement reference"
        case .viewTilt: "Camera view tilt"
        case .fieldOfView: "Camera field of view"
        case .tickDistance: "Click to toggle ticks; drag to set spacing"
        case .familyMeasure(let i): "Family \(i + 1) first unit · drag to calibrate projective ticks"
        case .horizon: "Toggle horizon through vanishing families 1 and 2"
        case .ellipseRadius: "Perspective circle radius"
        case .ellipseMode: "Cycle fixed, concentric and stepped ellipse sizing"
        case .ellipseDepthMode: "Toggle third-vanishing direction and depth sections"
        case .ellipseDepth: "Depth section · drag to slide; click next, Shift-click previous"
        case .ellipseVP: "Third vanishing point"
        case .ellipseSceneMode: "Toggle third-vanishing scene line pairs"
        case .ellipseScenePoint(let i): "Depth line \(i / 2 + 1), endpoint \(i % 2 + 1)"
        case .ellipseScale: "Scale top section for a cone"
        case .cameraMode: "Cycle camera perspective: 1, 2 or 3 point"
        case .sceneMode: "Toggle scene matching from line pairs"
        case .scenePoint(let i, let j): "Scene family \(i + 1), line \(j / 2 + 1), endpoint \(j % 2 + 1)"
        case .corner(let i): "Corner \(i + 1)"
        case .edge(let i): "Edge \(i + 1)"
        case .vanishing(let i): "Vanishing point \(i + 1)"
        }
    }
    var symbolName: String {
        switch self {
        case .chainReset: "arrow.counterclockwise"
        case .parallelSpacing: "arrow.left.and.right"
        case .constructionMode: "circle"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: "arrow.clockwise"
        case .size, .ellipseRadius: "arrow.up.left.and.arrow.down.right"
        case .axis: "angle"
        case .isometricAxis(let i): "\(i + 1).circle"
        case .isometricPreset: "square.stack.3d.up"
        case .radialMode: "lock.fill"
        case .radialBend: "point.topleft.down.to.point.bottomright.curvepath"
        case .radialSpacing: "arrow.left.and.right"
        case .boxMode: "cube"
        case .boxLearn: "graduationcap"
        case .boxSize(let i): "\(i + 1).square"
        case .cameraAxis(let i): "\(i + 1).circle"
        case .cameraCircle: "circle.square"
        case .axisPolicy: "arrow.triangle.branch"
        case .reference: "pin"
        case .viewTilt: "arrow.up.and.down"
        case .fieldOfView: "viewfinder"
        case .tickDistance: "ruler"
        case .familyMeasure: "ruler"
        case .horizon: "line.3.horizontal"
        case .ellipseMode: "circle"
        case .ellipseDepthMode: "square.3.layers.3d"
        case .ellipseDepth: "arrow.up.and.down"
        case .ellipseVP: "3.circle.fill"
        case .ellipseSceneMode: "line.diagonal"
        case .ellipseScenePoint(let i): "\(i / 2 + 1).circle"
        case .ellipseScale: "arrow.up.left.and.arrow.down.right"
        case .cameraMode: "camera"
        case .sceneMode: "line.diagonal"
        case .scenePoint(let i, _), .vanishing(let i): "\(i + 1).circle.fill"
        case .corner(let i): "\(i + 1).square"
        case .edge(let i): i % 2 == 0 ? "arrow.up.and.down" : "arrow.left.and.right"
        }
    }
}

@MainActor
private final class RulerHandle: NSView {
    var changed: ((CGPoint, Bool) -> Void)?
    private let role: RulerHandleID
    private var start = CGPoint.zero
    private var tracking: NSTrackingArea?
    init(frame: CGRect, role: RulerHandleID, settings: RulerSettings) {
        self.role = role
        super.init(frame: frame)
        let title: String
        let symbolName: String
        switch role {
        case .axisPolicy:
            title = settings.changesAxesAutomatically ? "Automatic axis changes · click for Control-only" : "Control-only axis changes · click for automatic"
            symbolName = settings.changesAxesAutomatically ? "arrow.triangle.branch" : "hand.point.up"
        case .reference:
            title = settings.fixedReference == nil ? "Pin measurement reference at pen position" : "Pinned reference · drag to move; click to unpin"
            symbolName = settings.fixedReference == nil ? "pin" : "pin.fill"
        case .boxLearn:
            title = settings.boxSettings.learnsDimensions ? "Learning box · Control tap captures dimension and changes axis" : "Explicit box extents · click to learn while drawing"
            symbolName = settings.boxSettings.learnsDimensions ? "graduationcap.fill" : "graduationcap"
        case .boxMode:
            title = settings.boxSettings.enabled ? "Box construction on · click to turn off" : "Box construction off · click to turn on"
            symbolName = settings.boxSettings.enabled ? "cube.fill" : "cube"
        case .radialMode:
            title = settings.radialSettings.locked ? "Locked radial angles · click for free" : "Free radial angles · click to lock"
            symbolName = settings.radialSettings.locked ? "lock.fill" : "lock.open.fill"
        case .isometricPreset:
            title = "\(settings.isometricPreset.map { ["30°", "2:1", "Dimetric"][$0] } ?? "Custom") isometric preset · click to cycle"
            symbolName = role.symbolName
        case .cameraMode:
            title = settings.camera.map { "\($0.points)-point camera · click to cycle" } ?? "Direct points · click to enable camera"
            symbolName = settings.camera.map { "\($0.points).square.fill" } ?? role.symbolName
        case .ellipseMode:
            title = "Ellipse size: \(settings.ellipseSizing.rawValue) · click to cycle"
            symbolName = settings.ellipseSizing == .fixed ? "circle" : (settings.ellipseSizing == .concentric ? "circle.dotted" : "circle.grid.2x2")
        case .sceneMode:
            title = settings.sceneLines == nil ? "Enable scene line pairs" : "Return to direct vanishing points"
            symbolName = role.symbolName
        default: title = role.title; symbolName = role.symbolName
        }
        setAccessibilityLabel(title)
        toolTip = title
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = role == .move || role == .rotate ? 16 : 6
        let icon = NSImageView(frame: CGRect(x: 8, y: 8, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .white
        icon.setAccessibilityElement(false)
        addSubview(icon)
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
