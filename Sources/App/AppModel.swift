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
    @Published var profileDisplayRemapped = false
    @Published var newProfileName = ""
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
    @Published private(set) var rulerPickerVisible = false
    var rulerKeyboardStatus: String { rulerOverlay.keyboardStatus }
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
        rulerOverlay.pickerShortcut = { [weak self] in self?.saved.pickerShortcut }
        rulerOverlay.onTogglePicker = { [weak self] in self?.toggleRulerPicker() }
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
            session.onDrawingProfile = { [weak self] id in
                DispatchQueue.main.async { self?.activateDrawingProfile(id) }
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
            return ScreenChoice(id: text, name: screen.localizedName, size: "\(Int(bounds.width)) × \(Int(bounds.height))", bounds: bounds)
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
        rulerOverlay.finishPicker(nil)
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
    var presetDisplays: [PresetDisplay] { screens.map { PresetDisplay(uuid: $0.id, bounds: $0.bounds) } }
    private func capturedProfile(name: String, settings: DriverSettings? = nil) -> PressureProfile {
        let settings = settings ?? draft
        let displays = presetDisplays, center = settings.rulerSettings.editingCenter
        let display = displays.first { $0.bounds.contains(center) } ?? displays.first
        return PressureProfile.capture(name: name, settings: settings, display: display)
    }
    private func persistProfile(_ profile: PressureProfile) throws {
        let existing = try profileStore.load()
        guard !existing.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw SettingsError.invalid("A profile with this name already exists.")
        }
        try profileStore.save(profile)
        pressureProfiles = PressureProfile.sorted(existing.filter { $0.id != profile.id } + [profile])
    }
    func savePressureProfile(name: String, updating: Bool = false) {
        error = nil
        let current = selectedPressureProfile
        let title = (updating ? current?.name ?? name : name).trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = capturedProfile(name: title)
        if updating, let current { profile.id = current.id }
        do {
            try persistProfile(profile)
            draft.pressureProfileID = profile.id
            message = "\(profile.scope.title) profile saved locally. Save & Apply to activate settings."
        } catch { self.error = error.localizedDescription }
    }
    func renamePressureProfile(_ name: String, duplicate: Bool = false) {
        guard var profile = selectedPressureProfile else { return }
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if duplicate {
                if profile.scope == .all { profile.id = UUID() }
                else {
                    var values = draft
                    let (prepared, _) = try preparedProfile(profile); prepared.apply(to: &values)
                    profile = capturedProfile(name: profile.name, settings: values)
                }
            }
            try persistProfile(profile)
            draft.pressureProfileID = profile.id
            message = duplicate ? "Profile duplicated locally." : "Profile renamed."
        } catch { self.error = error.localizedDescription }
    }
    private func preparedProfile(_ profile: PressureProfile) throws -> (PressureProfile, Bool) {
        try profile.validate()
        guard let drawing = profile.drawing else { return (profile, false) }
        let (remapped, changed) = try drawing.remapped(to: presetDisplays)
        var result = profile; result.drawing = remapped
        return (result, changed)
    }
    func selectPressureProfile(_ id: UUID?) {
        guard let id else { draft.pressureProfileID = nil; return }
        guard let profile = pressureProfiles.first(where: { $0.id == id }) else { message = "Preset unavailable; current settings kept."; return }
        do {
            let (prepared, remapped) = try preparedProfile(profile)
            var next = draft; prepared.apply(to: &next); try next.validate()
            draft = next; profileDisplayRemapped = remapped
            message = remapped ? "Ruler remapped to an active display. Review, then Save & Apply." : "Profile loaded for review. Save & Apply to activate."
        } catch { self.error = error.localizedDescription }
    }
    func resetProfileSections() {
        let scope = selectedPressureProfile?.scope ?? .basic
        let defaults = PressureProfile.capture(name: "Defaults", scope: scope, settings: DriverSettings())
        let id = draft.pressureProfileID
        defaults.apply(to: &draft); draft.pressureProfileID = id
        message = "\(scope.title) reset for review; saved profile unchanged."
    }
    func deletePressureProfile() {
        guard let id = draft.pressureProfileID else { return }
        do {
            try profileStore.delete(id)
            pressureProfiles.removeAll { $0.id == id }
            draft.pressureProfileID = nil
            message = "Profile moved to Trash. Active values and button releases are preserved; missing targets do nothing."
        } catch { self.error = error.localizedDescription }
    }
    func showPressureProfiles() { NSWorkspace.shared.open(profileStore.directory) }
    func importPressureProfile() {
        let panel = NSOpenPanel(); panel.title = "Import drawing profile"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try PressureProfileStore.read(url)
            guard !pressureProfiles.contains(where: { $0.id == profile.id }) else { throw SettingsError.invalid("This profile ID already exists. Duplicate it first or restore it through a settings backup.") }
            let (prepared, remapped) = try preparedProfile(profile)
            var next = draft; prepared.apply(to: &next); try next.validate()
            try persistProfile(prepared)
            draft = next; profileDisplayRemapped = remapped
            message = remapped ? "Profile imported; ruler remapped to an active display. Save & Apply to activate." : "Profile imported for review. Save & Apply to activate."
        } catch { self.error = "Import rejected: \(error.localizedDescription). Active settings were kept." }
    }
    func exportPressureProfile() {
        guard let profile = selectedPressureProfile else { return }
        let panel = NSSavePanel(); panel.title = "Export saved drawing profile"
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Drawing-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try profile.validate(); try SettingsFile.writeJSON(profile, to: url); message = "Saved profile exported; unsaved edits were not included." }
        catch { self.error = error.localizedDescription }
    }
    func profileBinding(_ key: String) -> Binding<UUID?> {
        Binding(get: { self.draft.profileBindings?[key] }, set: { value in
            var bindings = self.draft.profileBindings ?? [:]; bindings[key] = value
            self.draft.profileBindings = bindings.isEmpty ? nil : bindings
        })
    }
    private func cyclePressureProfile() { activateDrawingProfile(nil, basicCycle: true) }
    private func activateDrawingProfile(_ id: UUID?, basicCycle: Bool = false) {
        guard !stopping else { return }
        do {
            pressureProfiles = try profileStore.load()
            let profile = id.flatMap { id in pressureProfiles.first { $0.id == id } }
                ?? (id == nil ? PressureProfile.next(in: pressureProfiles.filter { ($0.scope == .basic) == basicCycle }, after: saved.pressureProfileID) : nil)
            guard let profile else { message = "Preset unavailable; current settings kept."; return }
            let (prepared, remapped) = try preparedProfile(profile)
            var next = saved; prepared.apply(to: &next); try next.validate()
            var nextDraft = draft; prepared.apply(to: &nextDraft)
            try SettingsFile.write(next, to: file.url)
            // Existing profile activation changes only processing on the input
            // owner, preserving held modifiers/mouse and deferring through lift.
            withSession { $0.applyPressureProfile(prepared) }
            processingChangePending = withSession { $0.processingChangePending }
            saved = next; draft = nextDraft; profileDisplayRemapped = remapped
            message = "Profile: \(profile.name)" + (remapped ? " · ruler remapped to an active display" : "")
        } catch { self.error = "Could not activate profile: \(error.localizedDescription)" }
    }
    func toggleRulerEditing() {
        rulerOverlay.finishPicker(nil)
        guard !withSession({ $0.output.isContact }) else { message = "Lift the pen before editing rulers."; return }
        guard saved.advancedFeaturesEnabled, saved.rulerSettings.enabled else { return }
        rulerEditing.toggle()
        configureRulerInteraction()
        rulerOverlay.setEditing(rulerEditing) { [weak self] ruler in _ = self?.moveRuler(ruler) }
    }
    private func configureRulerInteraction() {
        var next = saved
        if rulerEditing || rulerPickerVisible {
            next.rulerSettings.enabled = false
            next.stringSettings.enabled = false
        }
        withSession { [next] in $0.configure(next) }
    }
    func toggleRulerPicker() {
        if rulerPickerVisible { rulerOverlay.finishPicker(nil); return }
        let pointerHeld = [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
        guard running, !pointerHeld, !withSession({ $0.output.isContact || $0.output.heldMouse != nil }) else {
            message = "Start the driver and lift the pen before opening the ruler picker."; return
        }
        if rulerEditing { toggleRulerEditing() }
        rulerPickerVisible = true
        if !rulerOverlay.presentPicker(current: saved.rulerSettings.kind, rulerEnabled: saved.rulerSettings.enabled, finished: { [weak self] kind in
            guard let self else { return }
            self.rulerPickerVisible = false
            if kind == .toggleRuler {
                var ruler = self.saved.rulerSettings
                ruler.enabled.toggle()
                if ruler.enabled { ruler.visible = true }
                if self.moveRuler(ruler) {
                    self.draft.rulerSettings.enabled = ruler.enabled
                    self.draft.rulerSettings.visible = ruler.visible
                    self.message = ruler.enabled ? (self.saved.advancedFeaturesEnabled ? "Ruler on." : "Ruler enabled. Turn on Advanced features to use it.") : "Ruler off."
                }
                self.configureRulerInteraction()
                return
            }
            if case .ruler(let kind) = kind {
                let followsSavedKind = self.draft.rulerSettings.kind == self.saved.rulerSettings.kind
                var ruler = self.saved.rulerSettings; ruler.kind = kind
                if self.moveRuler(ruler) {
                    if followsSavedKind { self.draft.rulerSettings.kind = kind }
                    self.message = "Ruler: \(kind.title)."
                }
            }
            self.configureRulerInteraction()
        }) {
            rulerPickerVisible = false
            configureRulerInteraction()
            message = "Picker unavailable. \(rulerOverlay.keyboardStatus)"
        } else { configureRulerInteraction() }
    }
    func toggleRulerGuide() {
        guard !rulerEditing, !rulerPickerVisible else { return }
        defer { configureRulerInteraction() }
        do {
            var next = saved
            next.rulerSettings.visible.toggle()
            try SettingsFile.write(next, to: file.url)
            saved = next
            draft.rulerSettings.visible = next.rulerSettings.visible
            message = next.rulerSettings.visible ? "Ruler guides shown." : "Ruler guides hidden; snapping is unchanged."
        } catch { self.error = "Could not change ruler visibility: \(error.localizedDescription)" }
    }
    @discardableResult private func moveRuler(_ ruler: RulerSettings) -> Bool {
        do {
            var next = saved
            next.rulerSettings = ruler
            try next.validate()
            try SettingsFile.write(next, to: file.url)
            let wasClean = draft.ruler == saved.ruler
            saved = next
            if wasClean { draft.ruler = next.ruler }
            message = "Ruler position saved. Finish on-screen editing to draw."
            return true
        } catch { self.error = "Could not move ruler: \(error.localizedDescription)"; return false }
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
        NSApp.keyWindow?.makeFirstResponder(nil)
        rulerOverlay.finishPicker(nil)
        if rulerEditing { toggleRulerEditing() }
        do {
            try draft.validate()
            var next = draft
            let imported = next.pressureProfiles ?? []
            next.pressureProfiles = nil; next.rulerDisplay = nil
            let selected = (imported + pressureProfiles).first { $0.id == next.pressureProfileID }
            let prepared = try selected.map { try preparedProfile($0).0 }
            var profileChanges = saved; prepared?.apply(to: &profileChanges)
            let profileOnly = prepared != nil && profileChanges == next
            try profileStore.save(imported, settings: next, to: file.url)
            if !imported.isEmpty { pressureProfiles = PressureProfile.sorted(pressureProfiles.filter { old in !imported.contains { $0.id == old.id } } + imported) }
            withSession { [next] in
                if profileOnly, let prepared { $0.applyPressureProfile(prepared) }
                else { $0.configure(next) }
            }
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
            backup.rulerDisplay = presetDisplays.first { $0.bounds.contains(saved.rulerSettings.editingCenter) } ?? presetDisplays.first
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
            var candidate = try SettingsFile.read(url)
            candidate.advancedFeaturesEnabled = draft.advancedFeaturesEnabled
            var remapped = false
            let source = candidate.rulerDisplay ?? candidate.pressureProfiles?.first { $0.id == candidate.pressureProfileID }?.drawing?.display
            if let profiles = candidate.pressureProfiles {
                candidate.pressureProfiles = try profiles.map { profile in
                    let (prepared, changed) = try preparedProfile(profile); remapped = remapped || changed
                    return prepared
                }
            }
            if let ruler = candidate.ruler {
                var payload = DrawingPreset(scope: .ruler, settings: candidate, display: source)
                payload.ruler = ruler
                let (prepared, changed) = try payload.remapped(to: presetDisplays)
                candidate.ruler = prepared.ruler; remapped = remapped || changed
            }
            candidate.rulerDisplay = nil
            try candidate.validate()
            draft = candidate; profileDisplayRemapped = remapped
            message = "Imported for review; Advanced features choice preserved." + (remapped ? " Ruler display remapped." : "") + " Save & Apply to use these settings."
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
    let bounds: CGRect
}
#endif
