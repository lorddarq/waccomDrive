#if APP
import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

@main
struct WaccomDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    init() {
        if CommandLine.arguments.contains("--unregister-login") {
            do {
                let service = SMAppService.mainApp
                if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
                UserDefaults.standard.set(false, forKey: "driverEnabled")
                exit(0)
            } catch {
                fputs("Could not unregister login startup: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }
    var body: some Scene {
        Window("WaccomDrive", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 960, height: 720)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .saveItem) {
                Button("Save & Apply Settings") { model.save() }.keyboardShortcut("s")
                Button("Back Up Saved Settings…") { model.backup() }
                Button("Import Settings…") { model.importSettings() }
            }
        }
        MenuBarExtra("WaccomDrive", systemImage: model.running ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle") {
            StatusMenu(model: model)
        }
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Wacom Intuos Pro Large")
        Text(model.usbInterfaces > 0 ? "USB connected" : "USB disconnected")
        Text(model.running ? "Driver active" : "Driver paused")
        if let power = model.power {
            Text(power.wirelessModuleInstalled ? "Wireless module installed" : "Wireless module not installed")
            if power.wirelessModuleInstalled {
                Text("Battery: \(power.batteryDescription) · \(power.chargingDescription)")
            }
        }
        Divider()
        Button("Open Settings…") {
            if let window = NSApp.windows.first(where: { $0.title == "WaccomDrive" }) {
                window.makeKeyAndOrderFront(nil)
            } else { openWindow(id: "main") }
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.running ? "Pause Driver" : "Start Driver") { model.toggleDriver() }
        Divider()
        Button("Quit WaccomDrive") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
