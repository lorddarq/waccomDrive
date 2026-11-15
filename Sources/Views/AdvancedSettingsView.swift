#if APP
import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Advanced features", isOn: $model.draft.advancedFeaturesEnabled)
                Text("Off preserves normal pressure curves, smoothing, mapping and buttons. Save & Apply activates changes after the current stroke.").font(.caption).foregroundStyle(.secondary)
                if model.processingChangePending { Label("Change pending until pen lift", systemImage: "clock") }
            }
            Section("Pulled-string position smoothing") {
                Toggle("Enable pulled string", isOn: $model.draft.stringSettings.enabled)
                Slider(value: $model.draft.stringSettings.length, in: 0...500)
                    .accessibilityLabel("String length in screen points")
                number("String length (screen points)", value: $model.draft.stringSettings.length, range: 0...500, step: 0.1)
                Toggle("Show string guide over apps", isOn: $model.draft.stringSettings.guideVisible)
                Text("The small ring marks your pen input; the dot marks the stabilized output. The dashed circle shows the string length. The guide passes clicks through and keeps the painting app’s cursor.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset string settings") { model.draft.pulledString = nil }
                Text("The stroke follows when the pen pulls this distance ahead. Longer strings intentionally add distance lag, not a time delay. Zero is exact bypass. Hover stays direct; lift stops immediately without a catch-up tail.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.draft.advancedFeaturesEnabled {
                    Text("Enable Advanced features to apply position smoothing. Your string settings are retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            PressureCurveEditor(model: model)
            Section("Pressure processing") {
                Toggle("Enable pressure processing", isOn: $model.draft.processingSettings.enabled)
                Picker("Mode", selection: $model.draft.processingSettings.mode) {
                    ForEach(PressureProcessingMode.allCases) { Text($0.title).tag($0) }
                }
                switch model.draft.processingSettings.mode {
                case .bypass:
                    Text("Passes the response curve output directly, without pressure smoothing.")
                case .fixed:
                    number("Contact pressure (%)", value: Binding(get: { model.draft.processingSettings.fixedValue * 100 }, set: { model.draft.processingSettings.fixedValue = $0 / 100 }), range: 0...100)
                    Text("Constant output during real tip contact; adds no acquisition delay.")
                case .sampleAndHold:
                    Stepper("Acquisition reports: \(model.draft.processingSettings.sampleCount)", value: $model.draft.processingSettings.sampleCount, in: 1...64)
                    number("Acquisition timeout (ms)", value: $model.draft.processingSettings.acquisitionMilliseconds, range: 1...100)
                    Text("Outputs the running average immediately, then holds after the report count or timeout. Short strokes use only received reports.")
                case .movingAverage:
                    number("Window (ms)", value: $model.draft.processingSettings.windowMilliseconds, range: 1...100)
                    Text("Averages reports in this time window, up to 1,024 reports. A larger window adds response delay.")
                case .ema:
                    number("Time constant (ms)", value: $model.draft.processingSettings.emaMilliseconds, range: 0...50)
                    Text("Time-based smoothing. Larger values add response delay; 0 ms is immediate.")
                }
                Button("Reset pressure processing") { model.draft.pressureProcessing = nil }
                Text("Replaces baseline smoothing only when both switches are on. Lift resets pressure immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Pressure gain by pen speed") {
                Toggle("Enable speed pressure gain", isOn: $model.draft.speedSettings.enabled)
                number("Slow threshold (points/s)", value: $model.draft.speedSettings.slowSpeed, range: 0...10000)
                number("Fast threshold (points/s)", value: $model.draft.speedSettings.fastSpeed, range: 0...10000)
                number("Slow pressure gain (×)", value: $model.draft.speedSettings.slowGain, range: 0...4, step: 0.1)
                number("Fast pressure gain (×)", value: $model.draft.speedSettings.fastGain, range: 0...4, step: 0.1)
                number("Speed averaging (ms)", value: $model.draft.speedSettings.averagingMilliseconds, range: 0...100)
                Button("Reset speed gain to neutral") { model.draft.pressureSpeed = nil }
                LabeledContent("Live speed", value: "\(model.penSpeed.formatted(.number.precision(.fractionLength(0)))) points/s")
                LabeledContent("Live applied gain", value: "\(model.speedGain.formatted(.number.precision(.fractionLength(2))))×")
                Text("Speed uses raw mapped screen points before the pulled string. Gain follows pressure processing, so even fixed/held pressure can vary with speed. Set both gains to 1 for neutral output. Higher averaging adds response delay; 0 ms is immediate.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("First contact, invalid times and report gaps over 100 ms use neutral gain. Save & Apply activates changes at pen lift. Live values show applied settings, not unsaved edits.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.draft.advancedFeaturesEnabled {
                    Text("Advanced features is off; speed gain is bypassed and saved parameters are retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Live applied input / output") {
                LabeledContent("Raw sensor input", value: (model.pen.inProximity ? Double(model.pen.pressure) / 2047 : 0).formatted(.percent.precision(.fractionLength(1))))
                ProgressView(value: model.pen.inProximity ? Double(model.pen.pressure) / 2047 : 0).accessibilityLabel("Raw pressure")
                LabeledContent("Delivered pressure", value: model.processedPressure.formatted(.percent.precision(.fractionLength(1))))
                ProgressView(value: model.processedPressure).accessibilityLabel("Delivered pressure")
                Text("Applied settings, up to 20 updates per second. Unsaved edits do not change drawing.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func number(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        HStack {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
            Stepper(title, value: value, in: range, step: step).labelsHidden().accessibilityLabel(title)
        }
    }
}
#endif
