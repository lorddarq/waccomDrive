#if APP
import SwiftUI

struct PressureCurveEditor: View {
    @ObservedObject var model: AppModel
    @State private var selected = 1
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var editError: String?
    private var curve: EditablePressureCurve { model.draft.advancedPressureCurve ?? .converting(model.draft) }
    private var selectedIndex: Int { min(selected, curve.anchors.count - 1) }

    var body: some View {
        Section("Advanced pressure curve") {
            Toggle("Use advanced curve", isOn: Binding(get: { model.draft.advancedPressureCurve?.enabled == true }, set: { enabled in
                var next = curve; next.enabled = enabled; store(next)
            }))
            if !model.draft.advancedFeaturesEnabled {
                Text("Advanced features is off. Edits are retained; drawing uses the baseline response on Pen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Interpolation", selection: Binding(get: { curve.interpolation }, set: { mode in
                var next = curve; next.interpolation = mode; store(next)
            })) {
                Text("Linear").tag(EditablePressureCurve.Interpolation.linear)
                Text("Smooth").tag(EditablePressureCurve.Interpolation.smooth)
            }
            Toggle("Inverted response", isOn: Binding(get: { curve.inverted }, set: { inverted in
                var next = curve
                next.inverted = inverted
                next.anchors = next.anchors.map { PressureAnchor(input: $0.input, output: 1 - $0.output) }
                store(next)
            }))
            graph
            Picker("Selected anchor", selection: $selected) {
                ForEach(curve.anchors.indices, id: \.self) { index in
                    Text("Anchor \(index + 1)").tag(index)
                }
            }
            coordinateSlider("Input pressure", input: true)
            coordinateSlider("Output pressure", input: false)
            HStack {
                TextField("Input (%)", text: $inputText).onSubmit(applyCoordinates)
                    .disabled(selectedIndex == 0 || selectedIndex == curve.anchors.count - 1)
                TextField("Output (%)", text: $outputText).onSubmit(applyCoordinates)
                Button("Apply anchor", action: applyCoordinates)
            }
            HStack {
                Button("Add anchor") {
                    var next = curve
                    let i = min(selectedIndex, next.anchors.count - 2)
                    let a = next.anchors[i], b = next.anchors[i + 1]
                    let x = (a.input + b.input) / 2
                    next.anchors.insert(PressureAnchor(input: x, output: CompiledPressureCurve(next).response(x)), at: i + 1)
                    selected = i + 1; store(next)
                }.disabled(curve.anchors.count == 8)
                Button("Delete anchor", action: deleteAnchor)
                    .disabled(selectedIndex == 0 || selectedIndex == curve.anchors.count - 1)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading) {
                Button("Linear reset") { preset(0.5) }
                Button("Soft starting shape") { preset(0.75) }
                Button("Firm starting shape") { preset(0.25) }
                Button("Copy baseline curve") { store(.converting(model.draft)) }
            }
            if let editError { Text(editError).foregroundStyle(.red).accessibilityLabel("Curve edit error: \(editError)") }
            Text("Use sliders to fine-tune the selected anchor, drag a handle, or use arrow keys (0.1%). Sliders stop at neighboring anchors. Numeric coordinates apply together. Endpoints keep input at 0% and 100%; output may plateau. Save & Apply activates edits at pen lift.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: syncCoordinates)
        .onChange(of: selected) { _, _ in syncCoordinates() }
        .onChange(of: model.draft.advancedPressureCurve) { _, _ in syncCoordinates() }
    }

    private func coordinateSlider(_ title: String, input: Bool) -> some View {
        let index = selectedIndex
        let range = input ? curve.inputRange(at: index) : curve.outputRange(at: index)
        let value = Binding<Double>(get: {
            input ? curve.anchors[selectedIndex].input : curve.anchors[selectedIndex].output
        }, set: { value in
            let current = curve.anchors[selectedIndex]
            move(selectedIndex, input: input ? value : current.input, output: input ? current.output : value)
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(1))).monospacedDigit()
            }
            Slider(value: value, in: range)
                .labelsHidden().accessibilityLabel("Selected anchor \(title.lowercased())")
                .disabled(range.lowerBound == range.upperBound)
        }
    }

    private var graph: some View {
        let prepared = CompiledPressureCurve(curve)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Output pressure (%) · 100 at top, 0 at bottom").font(.caption)
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 20)
                let height = max(1, geometry.size.height - 20)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let rect = CGRect(x: 10, y: 10, width: width, height: height)
                        context.stroke(Path(rect), with: .color(.secondary), lineWidth: 1)
                        var path = Path()
                        for index in 0...200 {
                            let x = Double(index) / 200
                            let point = CGPoint(x: 10 + x * width, y: 10 + (1 - prepared.response(x)) * height)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }.accessibilityHidden(true)
                    ForEach(curve.anchors.indices, id: \.self) { index in
                        let anchor = curve.anchors[index]
                        Button { selected = index } label: {
                            Circle().fill(index == selectedIndex ? Color.accentColor : Color.primary)
                                .frame(width: 12, height: 12).padding(4)
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .position(x: 10 + anchor.input * width, y: 10 + (1 - anchor.output) * height)
                        .accessibilityLabel("Anchor \(index + 1)")
                        .accessibilityValue("Input \(anchor.input * 100, specifier: "%.1f") percent, output \(anchor.output * 100, specifier: "%.1f") percent")
                        .accessibilityAdjustableAction { direction in
                            selected = index
                            nudge(dx: 0, dy: direction == .increment ? 0.001 : -0.001)
                        }
                        .onMoveCommand { direction in
                            selected = index
                            switch direction {
                            case .left: nudge(dx: -0.001, dy: 0)
                            case .right: nudge(dx: 0.001, dy: 0)
                            case .up: nudge(dx: 0, dy: 0.001)
                            case .down: nudge(dx: 0, dy: -0.001)
                            @unknown default: break
                            }
                        }
                        .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("pressureCurve")).onChanged { drag in
                            selected = index
                            move(index, input: (drag.location.x - 10) / width, output: 1 - (drag.location.y - 10) / height)
                        })
                    }
                }.coordinateSpace(name: "pressureCurve")
            }.frame(height: 180)
            Text("Input pressure (%) · 0 → 100").font(.caption).frame(maxWidth: .infinity)
        }
    }
    private func store(_ candidate: EditablePressureCurve) {
        do {
            try candidate.validate()
            model.draft.advancedPressureCurve = candidate
            editError = nil
        } catch { editError = error.localizedDescription }
    }
    private func syncCoordinates() {
        let anchor = curve.anchors[selectedIndex]
        inputText = (anchor.input * 100).formatted(.number.precision(.fractionLength(0...6)))
        outputText = (anchor.output * 100).formatted(.number.precision(.fractionLength(0...6)))
    }
    private func applyCoordinates() {
        let separator = Locale.current.decimalSeparator ?? "."
        guard let input = Double(inputText.replacingOccurrences(of: separator, with: ".")),
              let output = Double(outputText.replacingOccurrences(of: separator, with: ".")) else {
            editError = "Enter valid input and output percentages."; return
        }
        var next = curve
        next.anchors[selectedIndex] = PressureAnchor(input: input / 100, output: output / 100)
        store(next)
    }
    private func move(_ index: Int, input: Double, output: Double) {
        var next = curve
        next.anchors[index] = PressureAnchor(
            input: index == 0 ? 0 : (index == next.anchors.count - 1 ? 1 : min(1, max(0, input))),
            output: min(1, max(0, output)))
        store(next)
    }
    private func nudge(dx: Double, dy: Double) {
        let anchor = curve.anchors[selectedIndex]
        move(selectedIndex, input: anchor.input + dx, output: anchor.output + dy)
    }
    private func deleteAnchor() {
        guard selectedIndex > 0, selectedIndex < curve.anchors.count - 1 else { return }
        var next = curve; next.anchors.remove(at: selectedIndex)
        selected = max(0, selectedIndex - 1); store(next)
    }
    private func preset(_ middle: Double) {
        var next = EditablePressureCurve()
        next.anchors[1].output = middle
        selected = 1; store(next)
    }
}
#endif
