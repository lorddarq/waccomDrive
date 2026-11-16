#if APP
import AppKit
import QuartzCore

enum RulerPickerAction: Equatable {
    case ruler(RulerKind), toggleRuler
    static let all = RulerKind.allCases.map { Self.ruler($0) } + [.toggleRuler]
}

// Logical Cocoa screen points; the same layout serves presentation and hit testing.
struct RulerPickerLayout {
    let frame: CGRect
    let opensUp: Bool
    let scale: Double
    init?(anchor: CGPoint, screen: CGRect) {
        guard [anchor.x, anchor.y, screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite),
              screen.width >= 200, screen.height >= 140 else { return nil }
        scale = min(1, (screen.width - 32) / 508, (screen.height - 32) / 300)
        let size = CGSize(width: 508 * scale, height: 300 * scale)
        opensUp = anchor.y + 256 * scale <= screen.maxY - 16
        let y = anchor.y - (opensUp ? 44 : 256) * scale
        frame = CGRect(x: min(screen.maxX - size.width - 16, max(screen.minX + 16, anchor.x - size.width / 2)),
                       y: min(screen.maxY - size.height - 16, max(screen.minY + 16, y)), width: size.width, height: size.height)
    }
    func localY(_ y: Double) -> Double { (opensUp ? y : 300 - y) * scale }
    var centers: [CGPoint] {
        RulerKind.allCases.indices.map { i in
            let angle = Double.pi - Double(i) * .pi / Double(RulerKind.allCases.count - 1)
            return CGPoint(x: (254 + 206 * cos(angle)) * scale, y: localY(44 + 206 * sin(angle)))
        } + [CGPoint(x: 254 * scale, y: localY(108))]
    }
    func hit(_ point: CGPoint) -> Int? {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return centers.firstIndex { hypot($0.x - local.x, $0.y - local.y) <= 26 * scale }
    }
}

@MainActor
final class RulerPicker {
    private var panel: GuidePanel?
    private var view: RulerPickerView?
    private(set) var layout: RulerPickerLayout?
    var isVisible: Bool { panel?.isVisible ?? false }
    var choice: RulerPickerAction? { view.map { RulerPickerAction.all[$0.highlighted] } }
    @discardableResult
    func present(current: RulerKind, rulerEnabled: Bool = true, anchor: CGPoint, screens: [CGRect], onChoose: @escaping (RulerPickerAction) -> Void) -> Bool {
        let screen = screens.first { $0.contains(anchor) } ?? screens.min {
            hypot($0.midX - anchor.x, $0.midY - anchor.y) < hypot($1.midX - anchor.x, $1.midY - anchor.y)
        }
        guard let screen, let layout = RulerPickerLayout(anchor: anchor, screen: screen) else { return false }
        self.layout = layout
        if panel == nil {
            let panel = GuidePanel(contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.title = "Ruler picker"; panel.backgroundColor = .clear; panel.isOpaque = false
            panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
            self.panel = panel
        }
        let view = RulerPickerView(layout: layout, current: current, rulerEnabled: rulerEnabled, onChoose: onChoose)
        self.view = view; panel!.contentView = view
        panel!.setFrame(layout.frame, display: true); panel!.orderFrontRegardless()
        return true
    }
    func hover(at point: CGPoint) {
        if let index = layout?.hit(point), view?.highlighted != index { view?.highlight(index) }
    }
    func navigate(_ delta: Int) {
        guard let view else { return }
        view.highlight((view.highlighted + delta + RulerPickerAction.all.count) % RulerPickerAction.all.count)
    }
    func directChoice(_ index: Int) -> RulerPickerAction? {
        guard RulerPickerAction.all.indices.contains(index) else { return nil }
        return RulerPickerAction.all[index]
    }
    func dismiss() { panel?.orderOut(nil); view = nil; layout = nil; panel?.contentView = nil }
}

@MainActor
private final class RulerPickerView: NSView {
    private var buttons: [NSButton] = []
    private let current: RulerKind
    private let rulerEnabled: Bool
    private let onChoose: (RulerPickerAction) -> Void
    private let name = NSTextField(labelWithString: "")
    private(set) var highlighted: Int
    init(layout: RulerPickerLayout, current: RulerKind, rulerEnabled: Bool, onChoose: @escaping (RulerPickerAction) -> Void) {
        self.current = current; self.rulerEnabled = rulerEnabled; self.onChoose = onChoose
        highlighted = RulerKind.allCases.firstIndex(of: current)!
        super.init(frame: CGRect(origin: .zero, size: layout.frame.size))
        wantsLayer = true
        let shape = CAShapeLayer(), path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: 0)); path.addLine(to: CGPoint(x: 8, y: 44))
        path.addArc(center: CGPoint(x: 254, y: 44), radius: 246, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: 500, y: 0)); path.closeSubpath()
        var transform = CGAffineTransform(a: layout.scale, b: 0, c: 0, d: layout.opensUp ? layout.scale : -layout.scale,
                                         tx: 0, ty: layout.opensUp ? 0 : 300 * layout.scale)
        shape.path = path.copy(using: &transform)
        shape.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        shape.strokeColor = NSColor.separatorColor.cgColor; shape.lineWidth = 1
        layer?.addSublayer(shape)
        let symbols = ["viewfinder", "cube", "line.diagonal", "sun.max", "circle", "line.diagonal", "line.3.horizontal", "point.topleft.down.to.point.bottomright.curvepath", "oval", "power"]
        for (i, action) in RulerPickerAction.all.enumerated() {
            let title = action == .toggleRuler ? (rulerEnabled ? "Turn ruler off" : "Turn ruler on") : RulerKind.allCases[i].title
            let center = layout.centers[i], size = 48 * layout.scale
            let button = NSButton(frame: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            button.title = ""; button.isBordered = false; button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbols[i], accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20 * layout.scale, weight: .medium))
            button.wantsLayer = true; button.layer?.cornerRadius = size / 2
            button.tag = i; button.target = self; button.action = #selector(select(_:))
            button.toolTip = title + (action == .ruler(current) ? " · Current ruler" : (action == .toggleRuler ? " · Guide and snapping" : ""))
            button.setAccessibilityLabel(button.toolTip)
            addSubview(button); buttons.append(button)
        }
        let currentCenter = layout.centers[highlighted], targetSize = 48 * layout.scale
        let check = NSImageView(frame: CGRect(x: currentCenter.x + targetSize / 2 - 14, y: currentCenter.y - targetSize / 2 + 1, width: 12, height: 12))
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = .systemGreen; check.setAccessibilityElement(false); addSubview(check)
        func labelFrame(y: Double, height: Double) -> CGRect {
            CGRect(x: 162 * layout.scale, y: (layout.opensUp ? y : 300 - y - height) * layout.scale,
                   width: 184 * layout.scale, height: height * layout.scale)
        }
        name.frame = labelFrame(y: 31, height: 20); name.font = .systemFont(ofSize: 13, weight: .medium)
        name.alignment = .center; addSubview(name)
        let hint = NSTextField(labelWithString: "← →   Enter   Esc   G: on/off")
        hint.frame = labelFrame(y: 8, height: 16); hint.alignment = .center
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; addSubview(hint)
        highlight(highlighted)
    }
    required init?(coder: NSCoder) { nil }
    func highlight(_ index: Int) {
        highlighted = index
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, button) in buttons.enumerated() {
            let selected = i == index
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).cgColor
            button.contentTintColor = selected ? .white : .labelColor
            button.layer?.borderWidth = RulerPickerAction.all[i] == .ruler(current) || RulerPickerAction.all[i] == .toggleRuler && rulerEnabled ? 2 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        name.stringValue = index == RulerKind.allCases.count ? (rulerEnabled ? "Turn ruler off" : "Turn ruler on") : RulerKind.allCases[index].title
        CATransaction.commit()
    }
    @objc private func select(_ sender: NSButton) { onChoose(RulerPickerAction.all[sender.tag]) }
}
#endif
