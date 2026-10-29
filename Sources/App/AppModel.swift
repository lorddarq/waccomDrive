#if APP
import SwiftUI
import AppKit
import CoreGraphics
import ColorSync
import CoreBluetooth
import IOKit.hid
import UniformTypeIdentifiers
import ServiceManagement

@MainActor
final class AppModel: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published var draft = DriverSettings()
    @Published private(set) var saved = DriverSettings()
    @Published private(set) var usbInterfaces = 0
    @Published private(set) var receiverPresent = false
    @Published private(set) var power: TabletPowerStatus?
    @Published private(set) var running = false
    @Published private(set) var pen = PenSample()
    @Published private(set) var pad = PadSample(buttons: 0, ring: nil)
    @Published private(set) var touchContacts = 0
    @Published private(set) var touchStatus = "Driver paused"
    @Published private(set) var bluetooth = "Not checked"
    @Published private(set) var screens: [ScreenChoice] = []
    @Published private(set) var usbIssue: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginMessage = ""
    @Published var error: String?
    @Published var message = "Settings are stored locally on this Mac."
    private let file = SettingsFile()
    private let session = TabletSession(logging: false)
    private var bluetoothManager: CBCentralManager?
    private var lastPreview = 0.0
    private var displayObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    var installed: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/WaccomDrive.app" }
    var dirty: Bool { draft != saved }
    var settingsPath: String { file.url.path }

    override init() {
        super.init()
        if FileManager.default.fileExists(atPath: file.url.path) {
            do { draft = try SettingsFile.read(file.url); saved = draft }
            catch { self.error = "Saved settings could not be loaded: \(error.localizedDescription). The file has been preserved." }
        }
        session.configure(saved)
        session.onConnection = { [weak self] count, receiver in
            self?.usbInterfaces = count; self?.receiverPresent = receiver
            self?.resumeDriverIfRequested()
        }
        session.onPen = { [weak self] sample in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPreview >= 0.05 || sample.buttons != pen.buttons || sample.inProximity != pen.inProximity || sample.inRange != pen.inRange {
                pen = sample; lastPreview = now
            }
        }
        session.onPower = { [weak self] in self?.power = $0 }
        session.onPad = { [weak self] in self?.pad = $0 }
        session.onTouch = { [weak self] count, status in
            guard let self else { return }
            if touchContacts != count { touchContacts = count }
            if touchStatus != status { touchStatus = status }
        }
        session.onError = { [weak self] in self?.error = $0 }
        refreshScreens()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    self.refreshLoginStatus()
                    if self.usbInterfaces == 0 { self.retryUSB() }
                }
            }
        }
        refreshLoginStatus()
        retryUSB()
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginMessage = status == .requiresApproval ? "Approve WaccomDrive in System Settings → General → Login Items." :
            (installed ? "The driver resumes on launch if it was active when you quit." : "Install WaccomDrive in Applications to enable login startup.")
    }
    func setLoginEnabled(_ enabled: Bool) {
        guard installed else { error = "Install WaccomDrive in Applications first."; return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch { self.error = error.localizedDescription; refreshLoginStatus() }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func beginUninstall() {
        guard installed, let script = Bundle.main.url(forResource: "Uninstall WaccomDrive", withExtension: "command") else {
            error = "The uninstaller is available in the installed app, or in the installer output folder."; return
        }
        // Terminal provides the confirmation and administrator authentication.
        guard NSWorkspace.shared.open(script) else { error = "Could not open the uninstaller in Terminal."; return }
    }
    private func resumeDriverIfRequested() {
        guard !running, usbInterfaces > 0, UserDefaults.standard.bool(forKey: "driverEnabled"), CGPreflightPostEventAccess() else { return }
        session.setPosting(true)
        running = true
    }

    func refreshScreens() {
        session.reset()
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            let bounds = CGDisplayBounds(id)
            return ScreenChoice(id: text, name: screen.localizedName, size: "\(Int(bounds.width)) × \(Int(bounds.height))")
        }
    }
    func retryUSB() {
        do { usbInterfaces = try session.start(); usbIssue = nil }
        catch {
            usbIssue = "Tablet input is unavailable. Open Permission Help for setup and troubleshooting."
            usbInterfaces = 0
        }
    }
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    func toggleDriver() {
        if running {
            session.setPosting(false); running = false
            UserDefaults.standard.set(false, forKey: "driverEnabled")
            return
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            message = "Accessibility access is needed to control the pointer. Open Permission Help."
            return
        }
        guard usbInterfaces > 0 else { error = "Connect the tablet by USB and choose Retry USB."; return }
        session.setPosting(true)
        running = true
        UserDefaults.standard.set(true, forKey: "driverEnabled")
        message = "Driver active. Changes take effect when you Save & Apply."
    }
    func save() {
        do {
            try SettingsFile.write(draft, to: file.url)
            session.configure(draft)
            saved = draft
            message = "Settings saved and applied."
        } catch { self.error = "Could not save settings: \(error.localizedDescription). Previous settings remain active." }
    }
    func backup() {
        let panel = NSSavePanel()
        panel.title = "Back up saved driver settings"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WaccomDrive-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SettingsFile.write(saved, to: url); message = "Backup saved to \(url.lastPathComponent)." }
        catch { self.error = error.localizedDescription }
    }
    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import driver settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try SettingsFile.read(url)
            draft = candidate
            message = "Imported for review. Save & Apply to use these settings."
        } catch { self.error = "Import rejected: \(error.localizedDescription). Current settings were kept." }
    }
    func checkBluetooth() {
        if bluetoothManager == nil {
            bluetoothManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetooth = switch central.state {
        case .poweredOn: "On"
        case .poweredOff: "Off"
        case .unauthorized: "Permission not granted"
        case .unsupported: "Unavailable"
        case .resetting: "Resetting"
        case .unknown: "Checking…"
        @unknown default: "Unknown"
        }
    }
    func stop() {
        session.stop()
        running = false
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
}

struct ScreenChoice: Identifiable {
    let id: String
    let name: String
    let size: String
}
#endif
