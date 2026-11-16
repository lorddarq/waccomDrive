#if APP
import SwiftUI
import AppKit

private enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", mapping = "Mapping", pen = "Pen", touch = "Touch", tablet = "Tablet buttons", advanced = "Advanced", rulers = "Rulers", settings = "Settings", help = "Help"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "rectangle.and.hand.point.up.left"
        case .mapping: "display"
        case .pen: "pencil.tip"
        case .touch: "hand.point.up.left"
        case .tablet: "button.horizontal"
        case .advanced: "slider.horizontal.3"
        case .rulers: "ruler"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var pane: Pane? = .overview
    @State private var settingsTarget: String?
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 195)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connection").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if let icon = model.connectionIcon, let image = TabletArtwork.connectionImage(icon) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 16, height: 16).accessibilityHidden(true)
                        }
                        Text(model.connectionDescription)
                    }
                    if model.usbIssue != nil { Text("USB access unavailable").foregroundStyle(.orange) }
                }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pane?.rawValue ?? "Overview").font(.title2.bold())
                    }
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 16)
                Divider()
                Group {
                    switch pane ?? .overview {
                    case .overview: overview
                    case .mapping: MappingView(model: model)
                    case .pen: PenSettingsView(model: model)
                    case .touch: TouchSettingsView(model: model)
                    case .tablet: TabletButtonsView(model: model)
                    case .advanced: AdvancedSettingsView(model: model)
                    case .rulers: RulerSettingsView(model: model)
                    case .settings: settings
                    case .help: PermissionHelpView(model: model, openInputSettings: {
                        settingsTarget = "input-thread"
                        pane = .settings
                    })
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text(model.dirty ? "Unsaved changes" : model.message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if model.dirty { Button("Discard changes") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        model.draft = model.saved
                    } }
                    Button("Save & Apply") { model.save() }
                }.padding(16)
            }
        }
        .frame(minWidth: 800, minHeight: 660)
        .alert("WaccomDrive", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 28) {
                    TabletAsset(name: "base").frame(width: 238, height: 254)
                    GroupBox {
                        VStack(spacing: 12) {
                            statusRow("Model", model.tabletHardware?.name ?? "Not detected")
                            statusRow("Serial No", model.tabletHardware?.serial ?? "Not reported")
                            statusRow("Driver version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                            statusRow("Tablet", model.tabletStatus)
                            if let issue = model.usbIssue {
                                Label(issue, systemImage: "hand.raised").font(.callout).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            switch model.connectionKind {
                            case .bluetooth:
                                statusRow("Tablet Bluetooth", model.tabletHardware?.bluetoothConnected == true ? "Connected" : "Capability reported")
                            case .receiver:
                                statusRow("Wireless receiver", "Detected · 056A:0084")
                            case .usb:
                                statusRow("Connection", "USB")
                            }
                            if let power = model.power {
                                statusRow("Tablet wireless module", power.wirelessModuleInstalled ? "Installed" : "Not installed")
                            }
                            if model.connectionKind != .usb {
                                Divider()
                                Text(model.connectionKind == .receiver ?
                                     (model.wireless?.supported == true ? "Wireless pen, tablet buttons, and touch use the saved driver settings." : "Switch on the tablet to establish its wireless link.") :
                                     "Bluetooth capability is reported by the tablet. Driver input currently requires the supported tablet over USB.")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Button("Refresh devices") { model.retryUSB() }
                                Spacer()
                                Button(model.running ? "Pause driver" : "Start driver") { model.toggleDriver() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }.padding(10)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    if let power = model.powerForDisplay, power.wirelessModuleInstalled || model.usbInterfaces > 0 {
                        let pluggedIn = power.showsUSBPower(usbConnected: model.usbInterfaces > 0)
                        GroupBox("Battery and charging") {
                            VStack(spacing: 12) {
                                HStack {
                                    Text(pluggedIn ? "Power source" : "Battery charge")
                                    Spacer()
                                    if pluggedIn, let image = TabletArtwork.connectionImage("usb") {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(width: 16, height: 16).accessibilityHidden(true)
                                    } else if let name = power.batteryIcon, let image = TabletArtwork.batteryImage(name) {
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .frame(width: 24, height: 24).accessibilityHidden(true)
                                    }
                                    Text(pluggedIn ? "Plugged in" : power.batteryDescription).foregroundStyle(.secondary).monospacedDigit()
                                }
                                if !pluggedIn { statusRow("Charging status", power.chargingDescription) }
                            }.padding(10)
                        }
                    }
                    GroupBox("Live pen input") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(model.pen.inProximity ? (model.pen.toolID & 0xFFF == 0x80A ? "Eraser in range" : "Pen in range") : "Pen out of range")
                                Spacer()
                                Text("Pressure \(Int(livePressure * 100))%").monospacedDigit()
                            }
                            ProgressView(value: livePressure)
                        }.padding(10)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unofficial Wacom driver").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("WaccomDrive is an independent project. It is not affiliated with, endorsed by, or supported by Wacom.")
                    Text("Supported models").fontWeight(.semibold)
                    Text("• Intuos Pro Medium PTH-651/K and Large PTH-851/K — direct USB or Wacom USB wireless receiver (056A:0084).")
                    Text("Provided as is, without warranty. Use at your own risk. Other models and native Bluetooth input are not supported.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(24)
        }
    }
    private var livePressure: Double { model.pen.inProximity ? Double(model.pen.pressure) / 2047 : 0 }
    private func statusRow(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
    private var settings: some View {
        ScrollViewReader { proxy in
        Form {
            Section("Installation and startup") {
                LabeledContent("Installation", value: model.installed ? "Installed in Applications" : "Development build")
                Toggle("Start at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    .disabled(!model.installed)
                Text(model.loginMessage).font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items Settings") { model.openLoginSettings() }
                Button("Uninstall WaccomDrive…", role: .destructive) { model.beginUninstall() }
                    .disabled(!model.installed)
                Text("Uninstall stops the driver and removes the installed app. Saved settings are kept unless you choose to remove them in the command-line uninstaller.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PressureProfilesView(model: model)
            Section("Input threading") {
                Toggle("Use dedicated input thread", isOn: $model.draft.usesDedicatedInputThread)
                Text("On by default. Changes require Save & Apply and an app restart. Off restores main-thread delivery.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Active input thread", value: model.inputThreadActive ? "Dedicated · user-interactive priority" : "Main thread")
                if model.inputThreadRestartPending { Label("App restart required", systemImage: "arrow.clockwise") }
            }
            .id("input-thread")
            Section("Pen delivery diagnostics") {
                Button("Reset pen timing") { model.resetPenTiming() }
                Button("Copy pen timing report") { model.copyPenTiming() }
                Text("Reset, move the pen continuously for a few seconds, then copy. Reports measure input callback cadence and processing/posting time; they do not measure screen FPS or end-to-end latency.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved settings") {
                LabeledContent("Storage", value: "On this Mac")
                Text("Save & Apply stores your mapping, button assignments, and pressure response. The driver uses the last saved settings.")
                    .foregroundStyle(.secondary)
                Button("Show settings in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.settingsPath)])
                }
            }
            Section("Backup and restore") {
                Button("Back Up Saved Settings…") { model.backup() }
                Button("Import Settings…") { model.importSettings() }
                Text("Backups contain your saved settings. Imports are validated and opened for review; Save & Apply activates them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Defaults") {
                Button("Restore defaults for review") { model.draft = DriverSettings() }
                Text("Nothing changes in the driver until you save.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .task {
            if let target = settingsTarget {
                await Task.yield()
                proxy.scrollTo(target, anchor: .top)
                settingsTarget = nil
            }
        }
        }
    }
}

struct TabletPreview: View {
    let settings: DriverSettings
    let pen: PenSample
    var tabletSize: CGSize = SupportedTablet.large.penSize
    var body: some View {
        GeometryReader { geo in
            let width = max(1, min(geo.size.width, geo.size.height * 321.327 / 209.983))
            let height = width * 209.983 / 321.327
            // Bounds of the SVG surface layer, including the faces layer’s 0.347-point inset.
            let surface = CGRect(x: width * 44.458 / 321.327, y: height * 20.6693 / 209.983,
                                 width: width * 254.466 / 321.327, height: height * 168.6447 / 209.983)
            let active = settings.activeArea(in: settings.displayBounds, tabletSize: tabletSize)
            ZStack(alignment: .topLeading) {
                TabletAsset(name: "mapping_faces").padding(width * 0.00108)
                TabletAsset(name: "mapping_strokes")
                Rectangle().fill(Color.accentColor.opacity(0.22))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: surface.width * active.width, height: surface.height * active.height)
                    .offset(x: surface.minX + surface.width * active.minX,
                            y: surface.minY + surface.height * active.minY)
                if pen.inProximity {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .offset(x: surface.minX + surface.width * Double(pen.x) / tabletSize.width - 4,
                                y: surface.minY + surface.height * Double(pen.y) / tabletSize.height - 4)
                }
            }
            .frame(width: width, height: height)
            .rotationEffect(.degrees(settings.rotate180 ? 180 : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tablet active area. \(pen.inProximity ? "Pen in range" : "Pen out of range").")
    }
}
#endif
