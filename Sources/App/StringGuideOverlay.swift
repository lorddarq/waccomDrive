#if APP
import AppKit
import QuartzCore

// Rendering only: this panel never receives input or participates in HID delivery.
@MainActor
final class StringGuideOverlay {
    private let panel = GuidePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let guide = GuideView()
    private var timer: Timer?
    private var snapshot: (() -> StringGuideSnapshot?)?
    private var primaryTop: CGFloat = 0

    init() {
        panel.contentView = guide
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.title = "Pulled-string guide"
        refreshDisplayGeometry()
    }
    func refreshDisplayGeometry() {
        // Quartz has a top-left origin; AppKit has a bottom-left origin.
        primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        guide.state = nil
        panel.orderOut(nil)
    }
    func start(snapshot: @escaping () -> StringGuideSnapshot?) {
        stop()
        self.snapshot = snapshot
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        snapshot = nil
        guide.state = nil
        panel.orderOut(nil)
    }
    private func update() {
        let next = snapshot?()
        guard next != guide.state else { return }
        guide.state = next
        guard let next else { panel.orderOut(nil); return }
        let rect = next.displayBounds
        let frame = CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        guide.updateLayers()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

@MainActor
final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class GuideView: NSView {
    var state: StringGuideSnapshot?
    private let radius = [CAShapeLayer(), CAShapeLayer()]
    private let string = [CAShapeLayer(), CAShapeLayer()]
    private let inputRing = [CAShapeLayer(), CAShapeLayer()]
    private let endpoint = CAShapeLayer()
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        let pairs = [(radius, [2.5, 1.0]), (string, [3.0, 1.5]), (inputRing, [2.0, 1.0])]
        for (layers, widths) in pairs {
            for (index, shape) in layers.enumerated() {
                shape.fillColor = nil
                shape.strokeColor = (index == 0 ? NSColor.black : NSColor.cyan).cgColor
                shape.lineWidth = widths[index]
                layer!.addSublayer(shape)
            }
        }
        for shape in radius { shape.lineDashPattern = [3, 4]; shape.opacity = 0.6 }
        string[0].opacity = 0.7
        endpoint.fillColor = NSColor.cyan.cgColor
        endpoint.strokeColor = NSColor.black.cgColor
        endpoint.lineWidth = 1
        layer!.addSublayer(endpoint)
    }
    required init?(coder: NSCoder) { nil }

    func updateLayers() {
        guard let state else { return }
        let rect = state.displayBounds
        // Layer coordinates are bottom-left based, unlike incoming Quartz points.
        let input = CGPoint(x: state.input.x - rect.minX, y: rect.maxY - state.input.y)
        let output = CGPoint(x: state.output.x - rect.minX, y: rect.maxY - state.output.y)
        let radiusPath = CGPath(ellipseIn: CGRect(x: output.x - state.length, y: output.y - state.length,
                                                width: 2 * state.length, height: 2 * state.length), transform: nil)
        let line = CGMutablePath()
        line.move(to: output); line.addLine(to: input)
        let ringPath = CGPath(ellipseIn: CGRect(x: input.x - 4, y: input.y - 4, width: 8, height: 8), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = CGRect(origin: .zero, size: rect.size)
        for shape in radius + string + inputRing + [endpoint] { shape.frame = frame }
        for shape in radius { shape.path = radiusPath }
        for shape in string { shape.path = line }
        for shape in inputRing { shape.path = ringPath }
        endpoint.path = CGPath(ellipseIn: CGRect(x: output.x - 2.5, y: output.y - 2.5, width: 5, height: 5), transform: nil)
        CATransaction.commit()
    }
}
#endif
