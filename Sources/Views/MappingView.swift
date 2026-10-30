#if APP
import SwiftUI

struct MappingView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Tablet active area") {
                TabletPreview(settings: model.draft, pen: model.pen).frame(height: 210)
                areaSlider("Left", key: \.areaX)
                areaSlider("Top", key: \.areaY)
                areaSlider("Width", key: \.areaWidth)
                areaSlider("Height", key: \.areaHeight)
                Button("Use full tablet area") {
                    model.draft.areaX = 0; model.draft.areaY = 0
                    model.draft.areaWidth = 1; model.draft.areaHeight = 1
                }
            }
            Section("Display") {
                Picker("Map tablet to", selection: $model.draft.displayUUID) {
                    Text("Main display (follow macOS)").tag("")
                    ForEach(model.screens) { screen in Text("\(screen.name) · \(screen.size)").tag(screen.id) }
                    if !model.draft.displayUUID.isEmpty && !model.screens.contains(where: { $0.id == model.draft.displayUUID }) {
                        Text("Saved display disconnected · using main").tag(model.draft.displayUUID)
                    }
                }
                Toggle("Keep tablet proportions", isOn: $model.draft.preserveAspect)
                Text("Uses a centered portion of the active area to avoid stretching. A disconnected display falls back to the main display.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Rotate tablet 180°", isOn: $model.draft.rotate180)
            }
        }.formStyle(.grouped)
    }
    private func areaSlider(_ label: String, key: WritableKeyPath<DriverSettings, Double>) -> some View {
        let isOffset = key == \.areaX || key == \.areaY
        return HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { model.draft[keyPath: key] }, set: { value in
                model.draft[keyPath: key] = value
                model.draft.areaWidth = min(model.draft.areaWidth, 1 - model.draft.areaX)
                model.draft.areaHeight = min(model.draft.areaHeight, 1 - model.draft.areaY)
                if !isOffset {
                    model.draft.areaX = min(model.draft.areaX, 1 - model.draft.areaWidth)
                    model.draft.areaY = min(model.draft.areaY, 1 - model.draft.areaHeight)
                }
            }), in: isOffset ? 0...0.95 : 0.05...1).accessibilityLabel(label)
            Text(model.draft[keyPath: key], format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
}
#endif
