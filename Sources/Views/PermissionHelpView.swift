#if APP
import SwiftUI
import AppKit

struct PermissionHelpView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Set up tablet access") {
                Text("macOS asks for two separate permissions. Input Monitoring lets WaccomDrive read the tablet; Accessibility lets it move the pointer and send pen or button actions to your apps.")
                Text("Grant access to WaccomDrive itself. Permissions granted to Codex or Terminal do not automatically apply to this app.")
                    .foregroundStyle(.secondary)
            }
            Section("1. Allow tablet input") {
                Text("Open System Settings → Privacy & Security → Input Monitoring. Enable WaccomDrive so it can receive pen position, pressure, tilt, and button reports.")
                Button("Open Input Monitoring Settings…") { model.openInputMonitoringSettings() }
            }
            Section("2. Allow pointer and button control") {
                Text("Open System Settings → Privacy & Security → Accessibility. Enable WaccomDrive so it can move the pointer, draw, click, and send your assigned shortcuts.")
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("3. Return to WaccomDrive") {
                Text("If macOS asks you to quit and reopen the app, do so. Otherwise return here, choose Retry USB, then Start driver. Test a stroke in your drawing app with pressure enabled.")
                Button("Retry USB") { model.retryUSB() }
                Button(model.running ? "Pause driver" : "Start driver") { model.toggleDriver() }
                LabeledContent("Tablet", value: model.usbInterfaces > 0 ? "USB connected" : "Not connected")
            }
            Section("Already enabled, but still blocked?") {
                Text("First quit and reopen WaccomDrive. If access still fails after an update or development rebuild, the permission entry may refer to an older copy. Remove that WaccomDrive entry with the minus button, add the app you are running with the plus button, and enable it again.")
                Text("For normal use, run the installed copy in Applications. Stop other driver instances before starting it so two copies do not send competing input.")
                    .foregroundStyle(.secondary)
                Button("Show This App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Text("WaccomDrive cannot grant these permissions for you. macOS keeps the decision in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
#endif
