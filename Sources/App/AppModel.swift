#if APP
import SwiftUI
import AppKit
import CoreGraphics
import ColorSync
import IOKit.hid
import UniformTypeIdentifiers
import ServiceManagement

@MainActor
final class AppModel: NSObject, ObservableObject {
    @Published var draft = DriverSettings()
    @Published private(set) var saved = DriverSettings()
    @Published private(set) var usbInterfaces = 0
    @Published private(set) var wireless: WirelessStatus?
    @Published private(set) var tabletHardware: TabletHardware?
    @Published private(set) var receiverPresent = false
    @Published private(set) var power: TabletPowerStatus?
    @Published private(set) var running = false
    @Published private(set) var pen = PenSample()
    @Published private(set) var pad = PadSample(buttons: 0, ring: nil)
    @Published private(set) var touchContacts = 0
    @Published private(set) var touchStatus = "Driver paused"
    @Published private(set) var screens: [ScreenChoice] = []
    @Published private(set) var usbIssue: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginMessage = ""
    @Published var error: String?
    @Published var message = "Settings are stored locally on this Mac."
    private let file = SettingsFile()
    private let session = TabletSession(logging: false)
    private var receiverTimer: Timer?
    private var lastPreview = 0.0
    private var displayObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    var installed: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/WaccomDrive.app" }
    var dirty: Bool { draft != saved }
    var settingsPath: String { file.url.path }
    var connectionKind: TabletHardware.ConnectionKind {
        TabletHardware.connectionKind(tablet: tabletHardware, receiverPresent: receiverPresent)
    }
    var inputAvailable: Bool { usbInterfaces > 0 || wireless?.supported == true }
    var connectionDescription: String {
        if tabletHardware?.bluetoothConnected == true { return "Bluetooth" }
        if usbInterfaces > 0 { return "USB Cable" }
        if wireless?.supported == true { return "Wireless receiver" }
        if connectionKind == .bluetooth { return "Bluetooth available" }
        return receiverPresent ? "Receiver detected" : "Disconnected"
    }
    var connectionIcon: String? {
        if tabletHardware?.bluetoothConnected == true { return "bluetooth-on" }
        if usbInterfaces > 0 { return "usb" }
        if wireless?.supported == true { return "wifi-full" }
        return receiverPresent ? "wifi-off" : nil
    }
    var tabletStatus: String {
        if tabletHardware?.bluetoothConnected == true { return "Connected over Bluetooth · input unavailable" }
        if usbInterfaces > 0 { return "Connected over USB" }
        if let wireless, wireless.connected { return wireless.supported ? "Connected through receiver" : "Unsupported wireless tablet" }
        if let tabletHardware { return tabletHardware.productID == 0x0317 ? "Detected · input unavailable" : "Detected · unsupported model" }
        return receiverPresent ? "Waiting for wireless tablet" : "Not connected"
    }

    override init() {
        super.init()
        if FileManager.default.fileExists(atPath: file.url.path) {
            do { draft = try SettingsFile.read(file.url); saved = draft }
            catch { self.error = "Saved settings could not be loaded: \(error.localizedDescription). The file has been preserved." }
        }
        session.configure(saved)
        session.onConnection = { [weak self] count, _ in
            self?.usbInterfaces = count
            self?.refreshReceiver()
            self?.resumeDriverIfRequested()
        }
        session.onPen = { [weak self] sample in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPreview >= 0.05 || sample.buttons != pen.buttons || sample.inProximity != pen.inProximity || sample.inRange != pen.inRange {
                pen = sample; lastPreview = now
            }
        }
        session.onWireless = { [weak self] status in
            guard let self else { return }
            wireless = status
            refreshReceiver()
            if !inputAvailable {
                session.setPosting(false); running = false
            } else { resumeDriverIfRequested() }
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
        refreshReceiver()
        receiverTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReceiver() }
        }
        if let receiverTimer { RunLoop.main.add(receiverTimer, forMode: .common) }
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
        guard !running, inputAvailable, UserDefaults.standard.bool(forKey: "driverEnabled"), CGPreflightPostEventAccess() else { return }
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
    private func refreshReceiver() {
        let present = WacomReceiver.isPresent()
        if present != receiverPresent { receiverPresent = present }
        var hardware = TabletHardware.read()
        if hardware == nil, let wireless, wireless.connected {
            hardware = TabletHardware(productID: wireless.productID,
                name: wireless.supported ? "Wacom Intuos Pro Large · PTH-851/K" : String(format: "Wacom tablet · 056A:%04X", wireless.productID),
                serial: nil, bluetoothCapable: false, bluetoothConnected: false)
        }
        if hardware != tabletHardware { tabletHardware = hardware }
    }
    func retryUSB() {
        refreshReceiver()
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
        guard inputAvailable else { error = "Connect the tablet by USB, or switch it on with the wireless receiver plugged in, then choose Refresh devices."; return }
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
    func stop() {
        receiverTimer?.invalidate(); receiverTimer = nil
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
