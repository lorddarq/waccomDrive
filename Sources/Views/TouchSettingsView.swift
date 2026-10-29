#if APP
import SwiftUI

struct TouchSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Surface touch") {
                Toggle("Enable surface touch", isOn: $model.draft.touchSettings.enabled)
                Text("Use one finger to move the pointer and two fingers to scroll. Surface touch is off by default for drawing.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Tap to click", isOn: $model.draft.touchSettings.tapToClick)
                    .disabled(!model.draft.touchSettings.enabled)
                HStack {
                    Text("Pointer speed")
                    Slider(value: $model.draft.touchSettings.pointerSpeed, in: 0.25...4)
                        .accessibilityLabel("Touch pointer speed")
                    Text(model.draft.touchSettings.pointerSpeed, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit().frame(width: 30)
                }.disabled(!model.draft.touchSettings.enabled)
            }
            Section("Palm rejection") {
                Toggle("Block touch while the pen is in range", isOn: $model.draft.touchSettings.palmRejection)
                Text("Touch is blocked as soon as the pen approaches, before it touches the tablet. Lift your fingers or palm after moving the pen away to resume touch. Keep the tablet's physical touch switch on to use surface touch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live status") {
                LabeledContent("Surface", value: model.touchStatus)
                LabeledContent("Detected contacts", value: String(model.touchContacts))
                LabeledContent("Pen", value: model.pen.inRange ? "In range" : "Out of range")
                Text("Changes take effect with Save & Apply. Touch control is active while this driver is running; pausing or quitting releases the touch interface.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If touch control is unavailable, another driver may own the interface. Palm rejection cannot be guaranteed until WaccomDrive has control.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
#endif
