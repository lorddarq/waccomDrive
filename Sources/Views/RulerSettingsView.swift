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
                HStack {
                    Text("Picker shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: $model.draft.pickerShortcut).frame(width: 180, height: 24)
                    Button("Clear") { model.draft.pickerShortcut = nil }.disabled(model.draft.pickerShortcut == nil)
                }
                Button(model.rulerPickerVisible ? "Close ruler picker" : "Open ruler picker") { model.toggleRulerPicker() }.disabled(!model.running)
                Text("Default: Control–Option–R. Lift first, then choose by pen/click, arrows and Enter, or 1–5. G turns the ruler on/off. Escape cancels. Save & Apply after changing the shortcut. Selecting a ruler preserves Advanced and snapping settings.").font(.caption).foregroundStyle(.secondary)
                number("Snapping accuracy (%)", value: Binding(get: { model.draft.rulerSettings.accuracy * 100 }, set: { model.draft.rulerSettings.accuracy = $0 / 100 }))
                Slider(value: $model.draft.rulerSettings.accuracy, in: 0...1).accessibilityLabel("Snapping accuracy")
                Slider(value: $model.draft.rulerSettings.opacity, in: 0.1...1).accessibilityLabel("Guide opacity")
                Button(model.rulerEditing ? "Finish on-screen editing" : "Edit rulers on screen") { model.toggleRulerEditing() }
                    .disabled(!model.saved.advancedFeaturesEnabled || !model.saved.rulerSettings.enabled)
                if model.rulerEditing { Text(model.rulerKeyboardStatus).font(.caption).foregroundStyle(.secondary) }
                if model.draft.rulerSettings.kind == .perspective || model.draft.rulerSettings.kind == .vanishing || model.draft.rulerSettings.kind == .isometric {
                    Picker("Direction family", selection: $model.draft.rulerSettings.family) {
                        Text("Automatic").tag(0)
                        ForEach(1...(model.draft.rulerSettings.kind == .isometric || model.draft.rulerSettings.camera != nil && model.draft.rulerSettings.kind == .perspective ? 3 : model.draft.rulerSettings.vanishingPoints.count), id: \.self) { Text("Family \($0)").tag($0) }
                    }
                    number("Direction acquisition (points)", value: $model.draft.rulerSettings.selectionDistance)
                    Toggle("Automatic axis changes", isOn: $model.draft.rulerSettings.changesAxesAutomatically)
                    Text("Automatic changes require sustained movement toward another axis. Control still changes axes manually. Acquisition distance applies to starts and turns.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Automatic selection waits for a clear direction. Tap Control while drawing to cycle axes without lifting; hold it while lifted to edit. Choose a family explicitly for nearly parallel lines. 0% accuracy is guide-only.").font(.caption).foregroundStyle(.secondary)
                if !model.draft.advancedFeaturesEnabled { Text("Enable Advanced features on the Advanced page, then Save & Apply.").foregroundStyle(.secondary) }
                if model.processingChangePending { Label("Change pending until pen lift", systemImage: "clock") }
            }
            Section("Guideline colors") {
                ForEach(Array(model.draft.rulerSettings.guideColorLabels.enumerated()), id: \.offset) { index, title in
                    HStack {
                        ColorPicker(title, selection: guideColor(index), supportsOpacity: false)
                        Button("Reset") { model.draft.rulerSettings.setGuideColor(nil, at: index) }
                            .disabled(model.draft.rulerSettings.guideColor(at: index) == nil)
                            .accessibilityLabel("Reset \(title) color")
                    }
                }
                Button("Reset this ruler's colors") { model.draft.rulerSettings.resetGuideColors() }
                Text("Colors are saved separately for each ruler. Choose Save & Apply to update the guides.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Geometry · logical screen points") {
                switch model.draft.rulerSettings.kind {
                case .radial, .isometric:
                    number("Center X", value: $model.draft.rulerSettings.centerX)
                    number("Center Y", value: $model.draft.rulerSettings.centerY)
                    if model.draft.rulerSettings.kind == .isometric {
                        HStack {
                            Button("Isometric 30°") { model.draft.rulerSettings.useIsometricPreset(0) }
                            Button("2:1") { model.draft.rulerSettings.useIsometricPreset(1) }
                            Button("Dimetric") { model.draft.rulerSettings.useIsometricPreset(2) }
                        }
                        Toggle("Independent axis angles", isOn: Binding(get: { model.draft.rulerSettings.axisAngles != nil }, set: { model.draft.rulerSettings.axisAngles = $0 ? model.draft.rulerSettings.isometricAngles : nil }))
                        if model.draft.rulerSettings.axisAngles != nil {
                            ForEach(0..<3, id: \.self) { i in number("Axis \(i + 1) angle (degrees)", value: $model.draft.rulerSettings.isometricAngles[i]) }
                        } else { number("Symmetric angle (degrees)", value: $model.draft.rulerSettings.angle) }
                        number("Rotation (degrees)", value: $model.draft.rulerSettings.orientation)
                        Text("Hold Control to edit each numbered axis or cycle presets. Rotation turns all axes together. Hover over a handle to identify it.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("Lock radial angles", isOn: $model.draft.rulerSettings.radialSettings.locked)
                        number("Rotation (degrees)", value: $model.draft.rulerSettings.angle)
                        number("Angular spacing (degrees)", value: $model.draft.rulerSettings.spacing)
                        number("Radial bend (-2 to 2)", value: $model.draft.rulerSettings.radialSettings.bend)
                        Slider(value: $model.draft.rulerSettings.radialSettings.bend, in: -2...2).accessibilityLabel("Radial bend")
                        Button("Straight radial lines") { model.draft.rulerSettings.radialSettings.bend = 0 }
                        Text("Free angles follow the hovering pen, then lock for the stroke. Bend is perpendicular deviation at 1,000 points, divided by 1,000. Curved rays stop at the center. Hold Control to change lock, bend or spacing; hover over a handle to identify it.").font(.caption).foregroundStyle(.secondary)
                    }
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
                        Toggle("Independent 3D axis inclines", isOn: Binding(get: { model.draft.rulerSettings.camera?.points == 3 && model.draft.rulerSettings.camera?.customAxes != nil }, set: { value in
                            var next = model.draft.rulerSettings.camera ?? RulerCamera(); next.enableCustomAxes(value); model.draft.rulerSettings.camera = next
                        }))
                        if model.draft.rulerSettings.camera?.points == 3, model.draft.rulerSettings.camera?.customAxes != nil {
                            ForEach(0..<3, id: \.self) { i in
                                number("Axis \(i + 1) azimuth offset (degrees)", value: cameraAxis(i, \.azimuth))
                                number("Axis \(i + 1) incline (degrees)", value: cameraAxis(i, \.incline))
                            }
                        }
                        Picker("Circle plane", selection: $model.draft.rulerSettings.circlePlane) {
                            ForEach(RulerCameraPlane.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        number("Circle diameter (points)", value: $model.draft.rulerSettings.circleDiameter)
                        Button("Create perspective ellipse from camera plane") {
                            if let next = model.draft.rulerSettings.cameraEllipse() { model.draft.ruler = next }
                            else { model.error = "The chosen circle plane is edge-on, collapsed or crosses the camera plane. Adjust view tilt, plane or diameter." }
                        }
                        Text("Circle planes use the pinned reference or view center. The second plane axis is orthogonalized for a true circle. Save & Apply after generating the ellipse.").font(.caption).foregroundStyle(.secondary)
                        Text("Hold Control to adjust the camera on screen. Hover over a handle to identify its function.").font(.caption).foregroundStyle(.secondary)
                    } else {
                    Toggle("Show horizon (families 1–2)", isOn: $model.draft.rulerSettings.showsHorizon)
                    Toggle("Match scene from line pairs", isOn: Binding(get: { model.draft.rulerSettings.sceneLines != nil }, set: { model.draft.rulerSettings.matchScene($0) }))
                    if model.draft.rulerSettings.sceneLines != nil {
                        Text("Hold Control to align colored line pairs to scene edges. Shift-drag moves a whole line; Option-drag aligns to the other line or screen axes (family 3 also aligns perpendicular to the horizon). Parallel pairs define infinity. Direct points: Shift-drag VP1/2 along the horizon; Option snaps near horizontal/vertical alignment.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Direct vanishing-point construction; scene line pairs override these points while enabled.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.draft.rulerSettings.vanishingPoints.indices, id: \.self) { i in
                        number("Vanishing point \(i + 1) X", value: $model.draft.rulerSettings.vanishingPoints[i].x)
                        number("Vanishing point \(i + 1) Y", value: $model.draft.rulerSettings.vanishingPoints[i].y)
                    }
                    Stepper("Vanishing points: \(model.draft.rulerSettings.vanishingPoints.count)", onIncrement: {
                        if model.draft.rulerSettings.vanishingPoints.count < 6 { model.draft.rulerSettings.vanishingPoints.append(RulerPoint(x: 700, y: 0)); if model.draft.rulerSettings.sceneLines != nil { model.draft.rulerSettings.matchScene(true) } }
                    }, onDecrement: {
                        if model.draft.rulerSettings.vanishingPoints.count > 1 { model.draft.rulerSettings.vanishingPoints.removeLast(); if model.draft.rulerSettings.sceneLines != nil { model.draft.rulerSettings.sceneLines?.removeLast() } }
                    })
                    }
                case .perspectiveEllipse:
                    Picker("Ellipse size", selection: $model.draft.rulerSettings.ellipseSizing) {
                        Text("Fixed ellipse").tag(RulerEllipseMode.fixed)
                        Text("Concentric through cursor").tag(RulerEllipseMode.concentric)
                        Text("Stepped concentric").tag(RulerEllipseMode.stepped)
                    }
                    number("Radius in plane (1 = inscribed)", value: $model.draft.rulerSettings.circleRadius)
                    number("Concentric radius step", value: $model.draft.rulerSettings.circleStep)
                    number("Plane move/resize step (unit plane)", value: $model.draft.rulerSettings.planeStep)
                    Toggle("Show plane grid while editing", isOn: $model.draft.rulerSettings.showsPlaneGrid)
                    Toggle("Depth sections (third vanishing direction)", isOn: Binding(get: { model.draft.rulerSettings.depthSettings.enabled }, set: { model.draft.rulerSettings.enableDepth($0) }))
                    if model.draft.rulerSettings.depthSettings.enabled {
                        Toggle("Match depth from scene lines", isOn: Binding(get: { model.draft.rulerSettings.depthSettings.sceneLines != nil }, set: { model.draft.rulerSettings.matchDepthScene($0) }))
                        if model.draft.rulerSettings.depthSettings.sceneLines == nil {
                            number("Third vanishing point X", value: $model.draft.rulerSettings.depthSettings.vanishingPoint.x)
                            number("Third vanishing point Y", value: $model.draft.rulerSettings.depthSettings.vanishingPoint.y)
                        } else {
                            ForEach(0..<4, id: \.self) { i in
                                number("Depth line \(i / 2 + 1), endpoint \(i % 2 + 1) X", value: depthPoint(i, \.x))
                                    .id("depth-\(i)-x")
                                number("Depth line \(i / 2 + 1), endpoint \(i % 2 + 1) Y", value: depthPoint(i, \.y))
                                    .id("depth-\(i)-y")
                            }
                            .id("depth-line-fields")
                        }
                        number("Depth offset (local points)", value: $model.draft.rulerSettings.depthSettings.offset)
                        number("Depth step (points)", value: $model.draft.rulerSettings.depthSettings.step)
                        number("Top section scale", value: $model.draft.rulerSettings.depthSettings.scale)
                        Toggle("Cylinder/cone tangent guides", isOn: $model.draft.rulerSettings.depthSettings.tangents)
                        Button("Return to reference section") { model.draft.rulerSettings.depthSettings.offset = 0; model.draft.rulerSettings.depthSettings.scale = 1 }
                        Text("Hold Control: layers toggles depth; arrows drag along depth or click for the next section (Shift-click for previous); resize changes top scale; line switches direct point/scene pairs. Tangents join the reference and top circles when visible. Plane edits make the current section the new reference.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Center and edge handles move in the projected plane. Shift snaps movement to plane steps, resizes corners, and moves opposite edges symmetrically. Option moves centers/edges in screen space or constrains a corner to an adjacent edge. Shift also snaps depth and radius. Concentric size locks at pen-down until lift.").font(.caption).foregroundStyle(.secondary)
                    Text("Four corners in clockwise or counterclockwise order. The guide is the projected circle inscribed in this rectangle.").font(.caption).foregroundStyle(.secondary)
                    Text("On small or thin ellipses, editing handles sit outside the guide to keep it visible.").font(.caption).foregroundStyle(.secondary)
                    ForEach(0..<4, id: \.self) { i in
                        number("Corner \(i + 1) X", value: $model.draft.rulerSettings.corners[i].x)
                            .id("corner-\(i)-x")
                        number("Corner \(i + 1) Y", value: $model.draft.rulerSettings.corners[i].y)
                            .id("corner-\(i)-y")
                    }
                    .id("ellipse-corner-fields")
                }
                Button("Reset ruler geometry and options") { model.draft.ruler = nil }
            }
            if model.draft.rulerSettings.kind == .isometric || model.draft.rulerSettings.kind == .perspective || model.draft.rulerSettings.kind == .vanishing {
                Section("Reference frame") {
                    Toggle("Pin measurement reference", isOn: Binding(get: { model.draft.rulerSettings.fixedReference != nil }, set: { model.draft.rulerSettings.fixedReference = $0 ? RulerPoint(x: model.draft.rulerSettings.centerX, y: model.draft.rulerSettings.centerY) : nil }))
                    if model.draft.rulerSettings.fixedReference != nil {
                        number("Reference X", value: reference(\.x))
                        number("Reference Y", value: reference(\.y))
                    }
                    Text("Hold Control and use the pin handle to freeze a reference at the pen position. Drag it to move; click to unpin. Drawing axes still follow each stroke.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.draft.rulerSettings.kind == .isometric || model.draft.rulerSettings.kind == .perspective && model.draft.rulerSettings.camera != nil {
                Section("Box construction") {
                    Toggle("Snap to bounded box", isOn: $model.draft.rulerSettings.boxSettings.enabled)
                    Toggle("Learn dimensions while drawing", isOn: $model.draft.rulerSettings.boxSettings.learnsDimensions)
                    ForEach(0..<3, id: \.self) { i in number("Axis \(i + 1) extent (points)", value: $model.draft.rulerSettings.boxSettings.extents[i]).disabled(model.draft.rulerSettings.boxSettings.learnsDimensions) }
                    if model.draft.rulerSettings.boxSettings.learnsDimensions {
                        Text("Tap Control to capture the dimension just drawn and advance to the next axis. Once all three are captured, edges are bounded. Lift clears learned dimensions. The graduation-cap handle toggles learning.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The box starts at pen-down. Choose an edge by moving along it; corners stop overshoot, then let you select an adjoining edge. Signed extents reverse axes. Hold Control: the cube toggles construction; numbered squares resize axes. Boxes crossing the camera plane are hidden and bypass snapping for that stroke.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.draft.rulerSettings.kind != .perspectiveEllipse {
                Section("Measurements") {
                    Toggle("Show measurement ticks", isOn: $model.draft.rulerSettings.measureSettings.visible)
                    number("Tick distance (points)", value: $model.draft.rulerSettings.measureSettings.distance)
                    Stepper("Subdivisions: \(model.draft.rulerSettings.measureSettings.divisions)", value: $model.draft.rulerSettings.measureSettings.divisions, in: 1...10)
                    if model.draft.rulerSettings.kind == .vanishing || model.draft.rulerSettings.kind == .perspective && model.draft.rulerSettings.camera == nil {
                        Toggle("Projective family measurements", isOn: Binding(get: { model.draft.rulerSettings.familyMeasurements != nil }, set: { enabled in
                            model.draft.rulerSettings.familyMeasurements = enabled ? Array(repeating: model.draft.rulerSettings.measureSettings, count: model.draft.rulerSettings.vanishingPoints.count) : nil
                        }))
                        if model.draft.rulerSettings.familyMeasurements != nil {
                            ForEach(model.draft.rulerSettings.vanishingPoints.indices, id: \.self) { i in
                                number("Family \(i + 1) first unit (points)", value: familyMeasurement(i, \.distance)).id("measure-\(i)")
                                Stepper("Family \(i + 1) subdivisions: \(model.draft.rulerSettings.measurement(for: i).divisions)", value: familyMeasurement(i, \.divisions), in: 1...10).id("divisions-\(i)")
                            }.id("family-measurements")
                        }
                        Text("Pin a common reference, then drag each ruler handle onto the first known unit. Equal 3D steps converge toward the VP; parallel directions stay evenly spaced. The first unit must lie before its VP or that family's ticks are hidden. Units are scene-relative, not physical lengths.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.draft.rulerSettings.kind == .radial { Text("Radial ticks mark equal steps along the ray’s starting direction, not arc length along its bend.").font(.caption).foregroundStyle(.secondary) }
                    Text("Perspective ticks measure equal world steps from the same stroke origin at image-plane depth. Compare lengths from a shared origin, not unrelated screen positions.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Hold Control while lifted to reveal editing handles; release Control to return to drawing. Select the ruler on this page. Drag handles to move, rotate or resize; release saves. Numeric controls here remain available for precision.").font(.caption).foregroundStyle(.secondary)
                Text("Over your painting app, keep Control held: arrows move 1 point, Option-arrows 0.1 point, Shift-arrows 10 points. Home centers the construction at the pointer; Backspace restores its state from the start of editing. Requires Accessibility permission. Driver text fields retain normal keyboard input.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func familyMeasurement<T>(_ index: Int, _ key: WritableKeyPath<RulerMeasurements, T>) -> Binding<T> {
        Binding(get: { model.draft.rulerSettings.measurement(for: index)[keyPath: key] }, set: { value in
            guard model.draft.rulerSettings.familyMeasurements != nil else { return }
            var measure = model.draft.rulerSettings.measurement(for: index)
            measure[keyPath: key] = value
            model.draft.rulerSettings.setMeasurement(measure, family: index)
        })
    }
    private func depthPoint(_ index: Int, _ key: WritableKeyPath<RulerPoint, Double>) -> Binding<Double> {
        Binding(get: {
            guard let lines = model.draft.rulerSettings.depthSettings.sceneLines, lines.indices.contains(index) else { return 0 }
            return lines[index][keyPath: key]
        }, set: { value in
            var depth = model.draft.rulerSettings.depthSettings
            // A departing field may commit after Discard has removed its construction.
            guard depth.enabled, let lines = depth.sceneLines, lines.indices.contains(index) else { return }
            depth.sceneLines![index][keyPath: key] = value
            model.draft.rulerSettings.depthSettings = depth
        })
    }
    private func cameraAxis(_ index: Int, _ key: WritableKeyPath<RulerCameraAxis, Double>) -> Binding<Double> {
        Binding(get: { (model.draft.rulerSettings.camera ?? RulerCamera()).worldAxesSettings[index][keyPath: key] }, set: { value in
            var next = model.draft.rulerSettings.camera ?? RulerCamera(); next.enableCustomAxes(true)
            next.worldAxesSettings[index][keyPath: key] = value; model.draft.rulerSettings.camera = next
        })
    }
    private func reference(_ key: WritableKeyPath<RulerPoint, Double>) -> Binding<Double> {
        Binding(get: { model.draft.rulerSettings.fixedReference?[keyPath: key] ?? 0 }, set: { value in
            model.draft.rulerSettings.fixedReference?[keyPath: key] = value
        })
    }
    private func guideColor(_ index: Int) -> Binding<Color> {
        Binding(get: { Color(nsColor: model.draft.rulerSettings.guideNSColor(at: index)) }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            model.draft.rulerSettings.setGuideColor(RulerGuideColor(red: min(1, max(0, color.redComponent)),
                green: min(1, max(0, color.greenComponent)), blue: min(1, max(0, color.blueComponent))), at: index)
        })
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
            TextField(title, value: Binding(get: { value.wrappedValue }, set: { next in
                if next != value.wrappedValue { value.wrappedValue = next }
            }), format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 130)
                .accessibilityLabel(title)
        }
    }
}
#endif
