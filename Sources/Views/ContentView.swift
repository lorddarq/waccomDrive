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
                    Label(model.usbInterfaces > 0 ? "USB connected" : "USB disconnected", systemImage: "cable.connector")
                    if model.usbIssue != nil { Text("USB access unavailable").foregroundStyle(.orange) }
                    Text(model.running ? "Driver active" : "Driver paused").foregroundStyle(model.running ? .green : .secondary)
                }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pane?.rawValue ?? "Overview").font(.title2.bold())
                        Text("Wacom Intuos Pro Large · PTH-851/K").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.running ? "Pause driver" : "Start driver", systemImage: model.running ? "pause.fill" : "play.fill") { model.toggleDriver() }
                        .buttonStyle(.borderedProminent)
                }.padding(24)
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
                    Button("Permission Help") { pane = .help }
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
                TabletPreview(settings: model.saved, pen: model.pen, buttons: model.pad.buttons)
                    .frame(height: 230)
                GroupBox("Connection") {
                    VStack(spacing: 12) {
                        statusRow("Tablet", model.usbInterfaces > 0 ? "Connected over USB" : "Not connected")
                        if let issue = model.usbIssue {
                            Label(issue, systemImage: "hand.raised").font(.callout).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        statusRow("Surface touch", model.touchStatus)
                        statusRow("Wireless receiver", model.receiverPresent ? "Receiver detected · wireless input not enabled" : "Not detected")
                        statusRow("Tablet wireless module", model.power.map { $0.wirelessModuleInstalled ? "Installed" : "Not installed" } ?? "Waiting for tablet status")
                        HStack {
                            Text("Mac Bluetooth"); Spacer(); Text(model.bluetooth).foregroundStyle(.secondary)
                            Button("Check") { model.checkBluetooth() }.controlSize(.small)
                        }
                        Divider()
                        Text("The PTH-851 uses a Wacom wireless module and USB receiver. Module presence and Mac Bluetooth power do not confirm a wireless tablet connection.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Retry USB") { model.retryUSB() }
                            Button("Permission Help") { pane = .help }
                            Spacer()
                        }
                    }.padding(10)
                }
                GroupBox("Battery and charging") {
                    VStack(spacing: 12) {
                        statusRow("Battery charge", model.power?.batteryDescription ?? "Not reported")
                        statusRow("Charging status", model.power?.chargingDescription ?? "Not reported")
                        Text("Read directly from the tablet's USB status reports. If the reading is unavailable or stale, no charge level is assumed.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(10)
                }
                GroupBox("Live pen input") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.pen.inProximity ? (model.pen.toolID & 0xFFF == 0x80A ? "Eraser in range" : "Pen in range") : "Pen out of range")
                            Spacer()
                            Text("Pressure \(Int(Double(model.pen.pressure) / 2047 * 100))%").monospacedDigit()
                        }
                        ProgressView(value: Double(model.pen.pressure), total: 2047)
                        Text("Tilt X \(model.pen.tiltX) · Tilt Y \(model.pen.tiltY)").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }.padding(24)
        }
    }
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
                Button("Save & Apply") { model.save() }
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
    let buttons: Int
    var body: some View {
        GeometryReader { geo in
            let width = max(1, min(geo.size.width - 40, geo.size.height / 0.57, 440.0))
            let height = width * 0.57
            let active = settings.activeArea(in: settings.displayBounds)
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                HStack(spacing: 18) {
                    VStack(spacing: 7) {
                        ForEach(1...4, id: \.self) { key in keyShape(key) }
                        Circle().strokeBorder(buttons & 1 != 0 ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 3)
                            .frame(width: 31, height: 31).accessibilityLabel("Ring center")
                        ForEach(5...8, id: \.self) { key in keyShape(key) }
                    }.frame(width: 30)
                    GeometryReader { area in
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4))
                            Rectangle().fill(Color.accentColor.opacity(0.12))
                                .frame(width: area.size.width * active.width, height: area.size.height * active.height)
                                .offset(x: area.size.width * active.minX, y: area.size.height * active.minY)
                            if pen.inProximity {
                                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                    .offset(x: area.size.width * Double(pen.x) / 65024 - 4, y: area.size.height * Double(pen.y) / 40640 - 4)
                            }
                        }
                    }
                }.padding(22)
            }.frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Tablet preview. Active area highlighted. \(pen.inProximity ? "Pen in range" : "Pen out of range").")
    }
    private func keyShape(_ key: Int) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(buttons & (1 << key) != 0 ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: 23, height: 8)
    }
}
#endif
