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
    @Published private(set) var pressureProfiles: [PressureProfile] = []
    @Published private(set) var saved = DriverSettings()
    @Published private(set) var usbInterfaces = 0
    @Published private(set) var wireless: WirelessStatus?
    @Published private(set) var tabletHardware: TabletHardware?
    @Published private(set) var receiverPresent = false
    @Published private(set) var power: TabletPowerStatus?
    @Published private(set) var running = false
    @Published private(set) var pen = PenSample()
    @Published private(set) var processedPressure = 0.0
    @Published private(set) var penSpeed = 0.0
    @Published private(set) var speedGain = 1.0
    @Published private(set) var processingChangePending = false
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
    private let profileStore = PressureProfileStore()
    private var input: TabletInputRuntime!
    private var stopping = false
    private func withSession<T>(_ body: @Sendable (TabletSession) -> T) -> T { input.perform(body) }
    var inputThreadActive: Bool { input.dedicated }
    var inputThreadRestartPending: Bool { saved.usesDedicatedInputThread != inputThreadActive }
    private var receiverTimer: Timer?
    private var previewTimer: Timer?
    private let stringOverlay = StringGuideOverlay()
    private let rulerOverlay = RulerOverlay()
    @Published private(set) var rulerEditing = false
    private var displayObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    var installed: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/WaccomDrive.app" }
    var dirty: Bool { draft != saved }
    var selectedPressureProfile: PressureProfile? { pressureProfiles.first { $0.id == draft.pressureProfileID } }
    var settingsPath: String { file.url.path }
    var connectionKind: TabletHardware.ConnectionKind {
        TabletHardware.connectionKind(tablet: tabletHardware, receiverPresent: receiverPresent)
    }
    var tabletSize: CGSize { (SupportedTablet(rawValue: tabletHardware?.productID ?? wireless?.productID ?? 0) ?? .large).penSize }
    var powerForDisplay: TabletPowerStatus? {
        power ?? (usbInterfaces > 0 ? TabletPowerStatus(wirelessModuleInstalled: false, batteryPercent: nil, charging: nil) : nil)
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
        if let tabletHardware { return SupportedTablet(rawValue: tabletHardware.productID) != nil ? "Detected · input unavailable" : "Detected · unsupported model" }
        return receiverPresent ? "Waiting for wireless tablet" : "Not connected"
    }

    override init() {
        super.init()
        if FileManager.default.fileExists(atPath: file.url.path) {
            do { draft = try SettingsFile.read(file.url); saved = draft }
            catch { self.error = "Saved settings could not be loaded: \(error.localizedDescription). The file has been preserved." }
        }
        do { pressureProfiles = try profileStore.load() }
        catch { self.error = "Could not load pressure profiles: \(error.localizedDescription)" }
        input = TabletInputRuntime(dedicated: saved.usesDedicatedInputThread)
        let initialSettings = saved
        withSession { $0.configure(initialSettings) }
        stringOverlay.start { [weak self] in self?.withSession { $0.output.stringGuide } }
        rulerOverlay.start { [weak self] in
            guard let self else { return nil }
            return self.rulerEditing ? self.saved.rulerSettings : self.withSession { $0.output.rulerGuideSettings }
        }
        rulerOverlay.selectedFamily = { [weak self] in self?.withSession { $0.output.rulerGuideFamily } }
        rulerOverlay.contactAnchor = { [weak self] in self?.withSession { $0.output.rulerGuideAnchor } ?? .zero }
        rulerOverlay.isContact = { [weak self] in self?.withSession { $0.output.isContact } ?? false }
        rulerOverlay.onToggleEditing = { [weak self] in self?.toggleRulerEditing() }
        rulerOverlay.onSelectKind = { [weak self] kind in self?.selectCanvasRuler(kind) }
        rulerOverlay.onControlBoundsChanged = { [weak self] bounds in
            self?.withSession { $0.output.overlayControlBounds = bounds }
        }
        rulerOverlay.onMenuTracking = { [weak self] tracking in
            self?.withSession { $0.output.overlayMenuTracking = tracking }
        }
        withSession { session in
            session.onConnection = { [weak self] count, _ in
                DispatchQueue.main.async {
                    self?.usbInterfaces = count
                    self?.refreshInputState()
                }
            }
            session.onWireless = { [weak self] status in
                DispatchQueue.main.async {
                    self?.wireless = status
                    self?.refreshInputState()
                }
            }
            session.onCyclePressureProfile = { [weak self] in
                DispatchQueue.main.async { self?.cyclePressureProfile() }
            }
            session.onTouchEnabledChanged = { [weak self] enabled in
                DispatchQueue.main.async { self?.persistTouchToggle(enabled) }
            }
            session.onError = { [weak self] error in
                DispatchQueue.main.async { self?.error = error }
            }
        }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let state = self.withSession { session in
                    session.output.recordMainLoopTick(now)
                    return (session.decoder.sample, session.output.outputPressure, session.output.currentSpeed,
                            session.output.currentSpeedGain, session.processingChangePending,
                            session.touch.contacts.count, session.touch.status)
                }
                if self.touchContacts != state.5 { self.touchContacts = state.5 }
                if self.touchStatus != state.6 { self.touchStatus = state.6 }
                guard NSApp.isActive else { return }
                if self.pen != state.0 { self.pen = state.0 }
                if self.processedPressure != state.1 { self.processedPressure = state.1 }
                if self.penSpeed != state.2 { self.penSpeed = state.2 }
                if self.speedGain != state.3 { self.speedGain = state.3 }
                if self.processingChangePending != state.4 { self.processingChangePending = state.4 }
            }
        }
        if let previewTimer { RunLoop.main.add(previewTimer, forMode: .common) }
        withSession { session in
            session.onPower = { [weak self] power in DispatchQueue.main.async { self?.power = power } }
            session.onPad = { [weak self] sample in DispatchQueue.main.async {
                guard let self, self.pad != sample else { return }
                self.pad = sample
            } }
        }
        refreshScreens()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self {
                    self.pen = self.withSession { $0.decoder.sample }
                    self.refreshLoginStatus()
                    if !self.inputAvailable { self.retryUSB() }
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

    private func persistTouchToggle(_ enabled: Bool) {
        guard !stopping else { return }
        var next = saved
        next.touchSettings.enabled = enabled
        draft.touchSettings.enabled = enabled
        do {
            try SettingsFile.write(next, to: file.url)
            saved = next
            message = enabled ? "Surface touch on." : "Surface touch off."
        } catch { self.error = "Touch changed, but could not be saved: \(error.localizedDescription). Save & Apply to retry." }
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
    private func refreshInputState() {
        guard !stopping else { return }
        refreshReceiver()
        if !inputAvailable {
            withSession { $0.setPosting(false) }; running = false
        } else { resumeDriverIfRequested() }
    }
    private func resumeDriverIfRequested() {
        guard !running, inputAvailable, UserDefaults.standard.bool(forKey: "driverEnabled"), CGPreflightPostEventAccess() else { return }
        withSession { $0.setPosting(true) }
        running = true
    }

    func refreshScreens() {
        stringOverlay.refreshDisplayGeometry()
        rulerOverlay.refreshDisplayGeometry()
        withSession { $0.reset(); $0.refreshDisplayBounds() }
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let text = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            let bounds = CGDisplayBounds(id)
            return ScreenChoice(id: text, name: screen.localizedName, size: "\(Int(bounds.width)) × \(Int(bounds.height))")
        }
    }
    private func refreshReceiver() {
        let began = ProcessInfo.processInfo.systemUptime
        defer { let duration = ProcessInfo.processInfo.systemUptime - began; withSession { $0.output.recordDiscoveryDuration(duration) } }
        let present = WacomReceiver.isPresent()
        if present != receiverPresent { receiverPresent = present }
        var hardware = TabletHardware.read()
        if hardware == nil, let wireless, wireless.connected {
            hardware = TabletHardware(productID: wireless.productID,
                name: SupportedTablet(rawValue: wireless.productID)?.name ?? String(format: "Wacom tablet · 056A:%04X", wireless.productID),
                serial: nil, bluetoothCapable: false, bluetoothConnected: false)
        }
        if hardware != tabletHardware { tabletHardware = hardware }
    }
    func retryUSB() {
        refreshReceiver()
        do { usbInterfaces = try withSession { session in Result { try session.start() } }.get(); usbIssue = nil }
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
            withSession { $0.setPosting(false) }; running = false
            UserDefaults.standard.set(false, forKey: "driverEnabled")
            return
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            message = "Accessibility access is needed to control the pointer. Open Permission Help."
            return
        }
        guard inputAvailable else { error = "Connect the tablet by USB, or switch it on with the wireless receiver plugged in, then choose Refresh devices."; return }
        withSession { $0.setPosting(true) }
        running = true
        UserDefaults.standard.set(true, forKey: "driverEnabled")
        message = "Driver active. Changes take effect when you Save & Apply."
    }
    func savePressureProfile(name: String, updating: Bool = false) {
        let current = selectedPressureProfile
        let title = (updating ? current?.name ?? name : name).trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PressureProfile(id: updating ? current?.id ?? UUID() : UUID(), name: title,
                                      sensitivity: draft.sensitivity, contactThreshold: draft.contactThreshold, pressureCurve: draft.pressureCurve, pressureSmoothing: draft.pressureSmoothing, advancedPressureCurve: draft.advancedPressureCurve)
        do {
            guard !pressureProfiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(title) == .orderedSame }) else {
                throw SettingsError.invalid("A pressure profile with this name already exists.")
            }
            try profileStore.save(profile)
            pressureProfiles = try profileStore.load()
            draft.pressureProfileID = profile.id
            message = "Pressure profile saved locally. Save & Apply to activate settings."
        } catch { self.error = error.localizedDescription }
    }
    func selectPressureProfile(_ id: UUID?) {
        draft.pressureProfileID = id
        pressureProfiles.first { $0.id == id }?.apply(to: &draft)
    }
    func deletePressureProfile() {
        guard let id = draft.pressureProfileID else { return }
        do {
            try profileStore.delete(id)
            pressureProfiles = try profileStore.load()
            draft.pressureProfileID = nil
            message = "Pressure profile moved to Trash."
        } catch { self.error = error.localizedDescription }
    }
    func showPressureProfiles() { NSWorkspace.shared.open(profileStore.directory) }
    private func cyclePressureProfile() {
        guard !stopping else { return }
        guard let profile = PressureProfile.next(in: pressureProfiles, after: saved.pressureProfileID) else { return }
        var next = saved
        profile.apply(to: &next)
        do {
            try SettingsFile.write(next, to: file.url)
            withSession { $0.applyPressureProfile(profile) }
            processingChangePending = withSession { $0.processingChangePending }
            saved = next
            profile.apply(to: &draft)
            message = "Pressure profile: \(profile.name)"
        } catch { self.error = "Could not activate pressure profile: \(error.localizedDescription)" }
    }
    func toggleRulerEditing() {
        guard !withSession({ $0.output.isContact }) else { message = "Lift the pen before editing rulers."; return }
        guard saved.advancedFeaturesEnabled, saved.rulerSettings.enabled else { return }
        rulerEditing.toggle()
        var next = saved
        if rulerEditing {
            next.rulerSettings.enabled = false
            next.stringSettings.enabled = false
        }
        withSession { [next] in $0.configure(next) }
        rulerOverlay.setEditing(rulerEditing) { [weak self] ruler in self?.moveRuler(ruler) }
    }
    func selectCanvasRuler(_ kind: RulerKind) {
        guard !withSession({ $0.output.isContact }) else { return }
        do {
            var next = saved
            next.rulerSettings.kind = kind
            next.rulerSettings.family = 0
            try next.validate()
            try SettingsFile.write(next, to: file.url)
            var active = next
            if rulerEditing { active.rulerSettings.enabled = false; active.stringSettings.enabled = false }
            withSession { [active] in $0.configure(active) }
            saved = next
            draft.rulerSettings.kind = kind
            draft.rulerSettings.family = 0
            message = "Ruler: \(kind.title)"
        } catch { self.error = "Could not select ruler: \(error.localizedDescription)" }
    }
    func toggleRulerGuide() {
        guard !rulerEditing else { return }
        do {
            var next = saved
            next.rulerSettings.visible.toggle()
            try SettingsFile.write(next, to: file.url)
            withSession { [next] in $0.configure(next) }
            saved = next
            draft.rulerSettings.visible = next.rulerSettings.visible
            message = next.rulerSettings.visible ? "Ruler guides shown." : "Ruler guides hidden; snapping is unchanged."
        } catch { self.error = "Could not change ruler visibility: \(error.localizedDescription)" }
    }
    private func moveRuler(_ ruler: RulerSettings) {
        do {
            var next = saved
            next.rulerSettings = ruler
            try next.validate()
            try SettingsFile.write(next, to: file.url)
            let wasClean = draft.ruler == saved.ruler
            saved = next
            if wasClean { draft.ruler = next.ruler }
            message = "Ruler position saved. Finish on-screen editing to draw."
        } catch { self.error = "Could not move ruler: \(error.localizedDescription)" }
    }
    func copyPenTiming() {
        let report = "WaccomDrive pen timing\nConnection: \(connectionDescription)\nInput thread: \(inputThreadActive ? "dedicated (user-interactive)" : "main")\nAdvanced: \(saved.advancedFeaturesEnabled); ruler: \(saved.rulerSettings.enabled); string: \(saved.stringSettings.enabled)\n" + withSession { $0.output.timing.summary }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        message = "Pen timing report copied."
    }
    func resetPenTiming() {
        withSession { $0.output.resetTiming() }
        message = "Pen timing reset. Move the pen, then copy the timing report."
    }
    func save() {
        if rulerEditing { toggleRulerEditing() }
        do {
            try draft.validate()
            if let imported = draft.pressureProfiles {
                for profile in imported { try profileStore.save(profile) }
                pressureProfiles = try profileStore.load()
            }
            var next = draft
            next.pressureProfiles = nil
            try SettingsFile.write(next, to: file.url)
            withSession { [next] in $0.configure(next) }
            processingChangePending = withSession { $0.processingChangePending }
            saved = next; draft = next
            message = "Settings saved and applied."
        } catch { self.error = "Could not save settings: \(error.localizedDescription). Previous settings remain active." }
    }
    func backup() {
        let panel = NSSavePanel()
        panel.title = "Back up saved driver settings"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WaccomDrive-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var backup = saved
            backup.pressureProfiles = pressureProfiles
            try SettingsFile.write(backup, to: url)
            message = "Backup saved to \(url.lastPathComponent)."
        }
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
        guard !stopping else { return }
        stopping = true
        stringOverlay.stop()
        rulerOverlay.stop()
        previewTimer?.invalidate(); previewTimer = nil
        receiverTimer?.invalidate(); receiverTimer = nil
        input.close()
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
