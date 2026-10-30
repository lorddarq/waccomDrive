#if APP
import SwiftUI
import AppKit

private enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", mapping = "Mapping", pen = "Pen", touch = "Touch", tablet = "Tablet buttons", settings = "Settings", help = "Help"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "rectangle.and.hand.point.up.left"
        case .mapping: "display"
        case .pen: "pencil.tip"
        case .touch: "hand.point.up.left"
        case .tablet: "button.horizontal"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var pane: Pane? = .overview
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
                    case .settings: settings
                    case .help: PermissionHelpView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text(model.dirty ? "Unsaved changes" : model.message)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if model.dirty { Button("Discard changes") { model.draft = model.saved } }
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
                            if let tablet = model.tabletHardware {
                                statusRow("Model", tablet.name)
                                if let serial = tablet.serial { statusRow("Serial No", serial) }
                            }
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
                    if let power = model.power, power.wirelessModuleInstalled {
                        GroupBox("Battery and charging") {
                            VStack(spacing: 12) {
                                statusRow("Battery charge", power.batteryDescription)
                                statusRow("Charging status", power.chargingDescription)
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
            }.padding(24)
        }
    }
    private var livePressure: Double { model.pen.inProximity ? Double(model.pen.pressure) / 2047 : 0 }
    private func statusRow(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
    private var settings: some View {
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
    }
}

struct TabletPreview: View {
    let settings: DriverSettings
    let pen: PenSample
    var body: some View {
        GeometryReader { geo in
            let width = max(1, min(geo.size.width, geo.size.height * 321.327 / 209.983))
            let height = width * 209.983 / 321.327
            // Bounds of the SVG surface layer, including the faces layer’s 0.347-point inset.
            let surface = CGRect(x: width * 44.458 / 321.327, y: height * 20.6693 / 209.983,
                                 width: width * 254.466 / 321.327, height: height * 168.6447 / 209.983)
            let active = settings.activeArea(in: settings.displayBounds)
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
                        .offset(x: surface.minX + surface.width * Double(pen.x) / 65024 - 4,
                                y: surface.minY + surface.height * Double(pen.y) / 40640 - 4)
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
