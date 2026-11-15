#if APP
import SwiftUI

struct RulerSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Screen-space ruler") {
                Toggle("Enable ruler", isOn: $model.draft.rulerSettings.enabled)
                Toggle("Show guide over apps", isOn: $model.draft.rulerSettings.visible)
                Picker("Ruler", selection: $model.draft.rulerSettings.kind) {
                    ForEach(RulerKind.allCases) { Text($0.title).tag($0) }
                }
                number("Snapping accuracy (%)", value: Binding(get: { model.draft.rulerSettings.accuracy * 100 }, set: { model.draft.rulerSettings.accuracy = $0 / 100 }))
                Slider(value: $model.draft.rulerSettings.accuracy, in: 0...1).accessibilityLabel("Snapping accuracy")
                Slider(value: $model.draft.rulerSettings.opacity, in: 0.1...1).accessibilityLabel("Guide opacity")
                Button(model.rulerEditing ? "Finish on-screen editing" : "Edit rulers on screen") { model.toggleRulerEditing() }
                    .disabled(!model.saved.advancedFeaturesEnabled || !model.saved.rulerSettings.enabled)
                if model.draft.rulerSettings.kind == .perspective || model.draft.rulerSettings.kind == .vanishing || model.draft.rulerSettings.kind == .isometric {
                    Picker("Direction family", selection: $model.draft.rulerSettings.family) {
                        Text("Automatic").tag(0)
                        ForEach(1...(model.draft.rulerSettings.kind == .isometric || model.draft.rulerSettings.camera != nil && model.draft.rulerSettings.kind == .perspective ? 3 : model.draft.rulerSettings.vanishingPoints.count), id: \.self) { Text("Family \($0)").tag($0) }
                    }
                    number("Direction acquisition (points)", value: $model.draft.rulerSettings.selectionDistance)
                }
                Text("Automatic selection waits for a clear direction, then locks until lift. Choose a family explicitly for nearly parallel lines. 0% accuracy is guide-only.").font(.caption).foregroundStyle(.secondary)
                if !model.draft.advancedFeaturesEnabled { Text("Enable Advanced features on the Advanced page, then Save & Apply.").foregroundStyle(.secondary) }
                if model.processingChangePending { Label("Change pending until pen lift", systemImage: "clock") }
            }
            Section("Geometry · logical screen points") {
                switch model.draft.rulerSettings.kind {
                case .radial, .isometric:
                    number("Center X", value: $model.draft.rulerSettings.centerX)
                    number("Center Y", value: $model.draft.rulerSettings.centerY)
                    number("Angle (degrees)", value: $model.draft.rulerSettings.angle)
                    if model.draft.rulerSettings.kind == .isometric { number("Rotation (degrees)", value: $model.draft.rulerSettings.orientation) }
                    if model.draft.rulerSettings.kind == .radial { number("Angular spacing (degrees)", value: $model.draft.rulerSettings.spacing) }
                case .perspective, .vanishing:
                    if model.draft.rulerSettings.kind == .perspective {
                        Toggle("Use camera perspective", isOn: Binding(get: { model.draft.rulerSettings.camera != nil }, set: { model.draft.rulerSettings.camera = $0 ? RulerCamera() : nil }))
                    }
                    if model.draft.rulerSettings.kind == .perspective, model.draft.rulerSettings.camera != nil {
                        Picker("Construction", selection: camera(\.points)) {
                            ForEach(1...3, id: \.self) { Text("\($0)-point perspective").tag($0) }
                        }
                        number("View center X", value: $model.draft.rulerSettings.centerX)
                        number("View center Y", value: $model.draft.rulerSettings.centerY)
                        number("Field of view (degrees)", value: camera(\.fieldOfView))
                        number("View radius (points)", value: camera(\.viewRadius))
                        if (model.draft.rulerSettings.camera?.points ?? 3) > 1 { number("Axis yaw (degrees)", value: camera(\.yaw)) }
                        if model.draft.rulerSettings.camera?.points == 3 { number("View tilt (degrees)", value: camera(\.pitch)) }
                        number("Horizon roll (degrees)", value: camera(\.roll))
                        Text("Hold Control: center moves the camera; ∠ changes yaw, ↕ changes tilt, FOV changes the field of view; rotate tilts the horizon and size changes view radius.").font(.caption).foregroundStyle(.secondary)
                    } else {
                    Text("Direct vanishing-point construction. Camera/FOV controls and scene-line matching are still in development.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.draft.rulerSettings.vanishingPoints.indices, id: \.self) { i in
                        number("Vanishing point \(i + 1) X", value: $model.draft.rulerSettings.vanishingPoints[i].x)
                        number("Vanishing point \(i + 1) Y", value: $model.draft.rulerSettings.vanishingPoints[i].y)
                    }
                    Stepper("Vanishing points: \(model.draft.rulerSettings.vanishingPoints.count)", onIncrement: {
                        if model.draft.rulerSettings.vanishingPoints.count < 6 { model.draft.rulerSettings.vanishingPoints.append(RulerPoint(x: 700, y: 0)) }
                    }, onDecrement: {
                        if model.draft.rulerSettings.vanishingPoints.count > 1 { model.draft.rulerSettings.vanishingPoints.removeLast() }
                    })
                    }
                case .perspectiveEllipse:
                    Text("Four corners in clockwise or counterclockwise order. The guide is the projected circle inscribed in this rectangle.").font(.caption).foregroundStyle(.secondary)
                    ForEach(0..<4, id: \.self) { i in
                        number("Corner \(i + 1) X", value: $model.draft.rulerSettings.corners[i].x)
                        number("Corner \(i + 1) Y", value: $model.draft.rulerSettings.corners[i].y)
                    }
                }
                Button("Reset ruler geometry and options") { model.draft.ruler = nil }
            }
            if model.draft.rulerSettings.kind == .isometric || model.draft.rulerSettings.kind == .perspective {
                Section("Measurements") {
                    Toggle("Show measurement ticks", isOn: $model.draft.rulerSettings.measureSettings.visible)
                    number("Tick distance (points)", value: $model.draft.rulerSettings.measureSettings.distance)
                    Stepper("Subdivisions: \(model.draft.rulerSettings.measureSettings.divisions)", value: $model.draft.rulerSettings.measureSettings.divisions, in: 1...10)
                    Text("Perspective ticks measure equal world steps from the same stroke origin at image-plane depth. Compare lengths from a shared origin, not unrelated screen positions.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Hold Control while lifted to reveal editing handles; release Control to return to drawing. The canvas bar also offers ruler selection and Edit ruler / Done. Drag handles to move, rotate or resize; release saves. Numeric controls here remain available for precision.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func camera<T>(_ key: WritableKeyPath<RulerCamera, T>) -> Binding<T> {
        Binding(get: { (model.draft.rulerSettings.camera ?? RulerCamera())[keyPath: key] }, set: { value in
            var next = model.draft.rulerSettings.camera ?? RulerCamera()
            next[keyPath: key] = value
            model.draft.rulerSettings.camera = next
        })
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                .accessibilityLabel(title)
        }
    }
}
#endif
