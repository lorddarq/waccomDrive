#if APP
import SwiftUI

struct ActionPicker: View {
    let title: String
    let pressed: Bool
    @Binding var action: ButtonAction
    var body: some View {
        HStack {
            Circle().fill(pressed ? Color.green : Color.secondary.opacity(0.25)).frame(width: 8, height: 8)
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
                HStack {
                    Text("Tip activation")
                    Slider(value: Binding(get: { Double(model.draft.contactThreshold) }, set: { model.draft.contactThreshold = Int($0) }), in: 0...2046, step: 1)
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
            ExpressKeyDiagram(selected: hoveredKey ?? selectedKey, pressed: model.pad.buttons, ring: model.pad.ring) { selectedKey = $0; hoveredKey = nil }
                .frame(height: 235).padding(.horizontal, 24).padding(.top, 12)
            Text((hoveredKey ?? selectedKey) == 0 ? "Target: touch-ring center button" : "Target: ExpressKey \(hoveredKey ?? selectedKey)")
                .font(.caption.weight(.medium)).padding(.bottom, 12)
            Divider()
            Form {
                Section("ExpressKeys") {
                    ForEach(1...8, id: \.self) { index in
                        mappingRow(index: index, title: "ExpressKey \(index)")
                    }
                    Text("Select a number on the diagram or hover a mapping row to locate its key. Green indicates a physical press. Shown with buttons on the left; press each key to verify numbering.")
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
    }
    private func mappingRow(index: Int, title: String) -> some View {
        HStack {
            Button { selectedKey = index; hoveredKey = nil } label: {
                Text(index == 0 ? "C" : String(index)).font(.caption.monospacedDigit().bold())
                    .frame(width: 24, height: 24)
                    .background((hoveredKey ?? selectedKey) == index ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).accessibilityLabel("Locate \(title) on tablet")
            ActionPicker(title: title, pressed: model.pad.buttons & (1 << index) != 0, action: $model.draft.tabletButtons[index])
                .onChange(of: model.draft.tabletButtons[index]) { _, _ in selectedKey = index }
        }.onHover { inside in hoveredKey = inside ? index : nil }
    }
}

private struct ExpressKeyDiagram: View {
    let selected: Int
    let pressed: Int
    let ring: Int?
    let select: (Int) -> Void
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 3) {
                ForEach(1...4, id: \.self) { index in key(index) }
                key(0).padding(.vertical, 4)
                ForEach(5...8, id: \.self) { index in key(index) }
            }.frame(width: 42)
            ZStack {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.35))
                Text("Intuos Pro Large").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 460).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
    private func key(_ index: Int) -> some View {
        let down = pressed & (1 << index) != 0
        return Button { select(index) } label: {
            Text(index == 0 ? "C" : String(index))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(down || selected == index ? Color.white : Color.primary)
                .frame(width: index == 0 ? 32 : 36, height: index == 0 ? 32 : 16)
                .background(down ? Color.green : (selected == index ? Color.accentColor : Color.secondary.opacity(0.2)),
                            in: RoundedRectangle(cornerRadius: index == 0 ? 16 : 4))
        }
        .buttonStyle(.plain)
        .overlay {
            if index == 0 {
                Circle().strokeBorder(ring == nil ? Color.secondary.opacity(0.3) : Color.green, lineWidth: 2).padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(index == 0 ? "Locate center button" : "Locate ExpressKey \(index)")
        .accessibilityValue(down ? "Pressed" : (selected == index ? "Targeted" : "Released"))
    }
}
#endif
