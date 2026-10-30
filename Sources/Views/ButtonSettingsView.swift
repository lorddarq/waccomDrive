#if APP
import SwiftUI

struct ActionPicker: View {
    let title: String
    let pressed: Bool
    @Binding var action: ButtonAction
    var body: some View {
        HStack {
            Circle().fill(pressed ? Color.green : (action == .none ? Color.secondary.opacity(0.25) : Color.accentColor)).frame(width: 8, height: 8)
                .accessibilityLabel(pressed ? "Pressed" : "Released")
            Picker(title, selection: $action) {
                ForEach(ButtonAction.allCases) { action in Text(action.title).tag(action) }
            }
        }
    }
}

struct PenSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Pressure sensitivity") {
                HStack {
                    Text("Firm")
                    Slider(value: $model.draft.sensitivity, in: 0...1).accessibilityLabel("Pressure sensitivity")
                    Text("Soft")
                }
                Text("Softer response reaches higher brush pressure with less pen force. The middle position is linear.")
                    .font(.caption).foregroundStyle(.secondary)
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.stroke(Path(rect), with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    var path = Path()
                    for index in 0...100 {
                        let point = CGPoint(x: size.width * Double(index) / 100,
                                            y: size.height * (1 - model.draft.pressure(Int(Double(index) / 100 * 2047))))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                }.frame(height: 100).accessibilityLabel("Pressure response curve")
                HStack {
                    Text("Live response preview")
                    ProgressView(value: model.draft.pressure(model.pen.pressure))
                    Text(model.draft.pressure(model.pen.pressure), format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45)
                }
                LabeledContent("Live tilt", value: "X \(model.pen.tiltX) · Y \(model.pen.tiltY)")
                HStack {
                    Text("Tip activation")
                    Slider(value: Binding(get: { Double(model.draft.contactThreshold) }, set: { model.draft.contactThreshold = Int($0.rounded()) }), in: 0...2046)
                        .accessibilityLabel("Tip activation threshold")
                    Text("\(model.draft.contactThreshold)").monospacedDigit().frame(width: 45)
                }
                Text("Raw pressure needed to click. Raise only to prevent accidental contact.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pen buttons") {
                ForEach(0..<2, id: \.self) { index in
                    ActionPicker(title: "Pen button \(index + 1)", pressed: model.pen.buttons & (1 << index) != 0, action: $model.draft.penButtons[index])
                }
                Text("Press a side button to identify it by the live indicator. Hold actions stay down until the button is released; shortcuts run once per press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct TabletButtonsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedKey = 1
    @State private var hoveredKey: Int?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected").foregroundStyle(.secondary)
                    Text((hoveredKey ?? selectedKey) == 0 ? "Ring center" : "ExpressKey \(hoveredKey ?? selectedKey)")
                        .fontWeight(.semibold)
                }.frame(width: 195, alignment: .leading).padding(.bottom, 16)
                ExpressKeyDiagram(selected: hoveredKey ?? selectedKey, hovered: hoveredKey, pressed: model.pad.buttons, ring: model.pad.ring, actions: model.draft.tabletButtons, ringCustomized: model.draft.ringSettings != RingSettings()) {
                    selectedKey = $0; hoveredKey = nil
                }
            }.frame(height: 264).padding(.horizontal, 24).padding(.bottom, 4)
            Divider()
            Form {
                Section("ExpressKey Customization") {
                    ForEach(1...8, id: \.self) { index in
                        mappingRow(index: index, title: "ExpressKey \(index)")
                    }
                    Text("Blue marks customized or hovered controls; black is the default. Click a key or hover its row to locate it. Green indicates a physical press.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Touch ring") {
                    mappingRow(index: 0, title: "Center button")
                    LabeledContent("Ring position", value: model.pad.ring.map(String.init) ?? "Not touched")
                    Toggle("Use ring to change brush size", isOn: $model.draft.ringSettings.enabled)
                    Toggle("Reverse ring direction", isOn: $model.draft.ringSettings.reversed)
                        .disabled(!model.draft.ringSettings.enabled)
                    HStack {
                        Text("Slow")
                        Slider(value: Binding(get: { Double(19 - model.draft.ringSettings.stepsPerShortcut) },
                                              set: { model.draft.ringSettings.stepsPerShortcut = 19 - Int($0) }), in: 1...18, step: 1)
                            .accessibilityLabel("Touch-ring brush size response")
                        Text("Fast")
                    }.disabled(!model.draft.ringSettings.enabled)
                    Text(model.draft.ringSettings.reversed ? "Clockwise makes the brush smaller; counterclockwise makes it larger." : "Clockwise makes the brush larger; counterclockwise makes it smaller.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Uses the [ and ] brush-size shortcuts in the active app. The center button keeps its own assignment. Save & Apply to activate changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .onChange(of: model.pad.buttons) { previous, current in
            let newlyPressed = current & ~previous
            if let index = (0...8).first(where: { newlyPressed & (1 << $0) != 0 }) {
                selectedKey = index; hoveredKey = nil
            }
        }
    }
    private func mappingRow(index: Int, title: String) -> some View {
        ActionPicker(title: title, pressed: model.pad.buttons & (1 << index) != 0, action: $model.draft.tabletButtons[index])
            .onChange(of: model.draft.tabletButtons[index]) { _, _ in selectedKey = index }
            .contentShape(Rectangle())
            .onHover { inside in hoveredKey = inside ? index : nil }
    }
}

private struct ExpressKeyDiagram: View {
    let selected: Int
    let hovered: Int?
    let pressed: Int
    let ring: Int?
    let actions: [ButtonAction]
    let ringCustomized: Bool
    let select: (Int) -> Void

    // Hit regions in the shared 479 × 264 viewBox of the two supplied close-ups.
    private func region(_ index: Int) -> CGRect {
        if index == 0 { return CGRect(x: 32, y: 118, width: 29, height: 29) }
        let tops: [Double] = [15.7, 34.9, 54, 73.2, 177.1, 196.3, 215.4, 234.6]
        return CGRect(x: 35, y: tops[index - 1], width: 23, height: 15)
    }
    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 479, geo.size.height / 264)
            ZStack(alignment: .topLeading) {
                TabletAsset(name: "express_keys")
                ForEach(0...8, id: \.self) { index in
                    let rect = region(index)
                    let down = pressed & (1 << index) != 0
                    if (actions[index] != .none || hovered == index || down), let image = TabletArtwork.keyOverlay(index) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .hueRotation(.degrees(down ? -85 : 0)).allowsHitTesting(false)
                    }
                    if selected == index {
                        RoundedRectangle(cornerRadius: index == 0 ? 18 : 4)
                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                            .frame(width: (rect.width + 6) * scale, height: (rect.height + 6) * scale)
                            .offset(x: (rect.minX - 3) * scale, y: (rect.minY - 3) * scale)
                            .allowsHitTesting(false)
                    }
                    Button { select(index) } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .frame(width: (rect.width + 8) * scale, height: (rect.height + 4) * scale)
                        .offset(x: (rect.minX - 4) * scale, y: (rect.minY - 2) * scale)
                        .accessibilityLabel(index == 0 ? "Ring center" : "ExpressKey \(index)")
                        .accessibilityValue(down ? "Pressed" : (selected == index ? "Selected" : "Released"))
                }
                if (ringCustomized || ring != nil), let image = TabletArtwork.ringOverlay {
                    Image(nsImage: image).resizable().scaledToFit()
                        .hueRotation(.degrees(ring != nil ? -85 : 0)).allowsHitTesting(false)
                }
            }
            .frame(width: 479 * scale, height: 264 * scale)
            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
