import Foundation
import CoreGraphics
import ColorSync

enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none, rightClick, middleClick, undo, redo, brush, eraser, brushSmaller, brushLarger, space, shift, option, command, control, toggleTouch, cyclePressureProfile, customKey
    var id: String { rawValue }
    var title: String {
        switch self {
        case .customKey: "Custom shortcut…"
        case .none: "No action"
        case .rightClick: "Right click"
        case .middleClick: "Middle click"
        case .undo: "Undo (⌘Z)"
        case .redo: "Redo (⇧⌘Z)"
        case .brush: "Brush (B)"
        case .eraser: "Eraser (E)"
        case .brushSmaller: "Smaller brush ([)"
        case .brushLarger: "Larger brush (])"
        case .space: "Space / pan"
        case .shift: "Shift"
        case .option: "Option"
        case .command: "Command"
        case .control: "Control"
        case .toggleTouch: "Touch on/off"
        case .cyclePressureProfile: "Cycle pressure profiles"
        }
    }
}

struct CustomKeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64
    var label: String
    static let allowedModifiers = CGEventFlags([.maskCommand, .maskShift, .maskAlternate, .maskControl]).rawValue
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers }
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode); hasher.combine(modifiers) }
}

struct PressureCurve: Codable, Equatable {
    // Output pressure at 25%, 50%, and 75% of native input. Endpoints stay 0 and 1.
    var light = 0.25
    var medium = 0.5
    var firm = 0.75

    func validate() throws {
        guard [light, medium, firm].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              light <= medium, medium <= firm else {
            throw SettingsError.invalid("Pressure curve points must increase from 0% to 100%.")
        }
    }
    func response(_ input: Double) -> Double {
        let x = min(1, max(0, input)) * 4
        let index = min(3, Int(x))
        let points = [0, light, medium, firm, 1]
        return points[index] + (points[index + 1] - points[index]) * (x - Double(index))
    }
}

struct TouchSettings: Codable, Equatable {
    var enabled = false
    var palmRejection = true
    var tapToClick = true
    var pointerSpeed = 1.5
}

struct RingSettings: Codable, Equatable {
    var enabled = true
    var reversed = false
    var stepsPerShortcut = 3
}

struct DriverSettings: Codable, Equatable {
    var version = 1
    var displayUUID = ""
    var preserveAspect = false
    var rotate180 = false
    var areaX = 0.0, areaY = 0.0, areaWidth = 1.0, areaHeight = 1.0
    var sensitivity = 0.5
    var pressureCurve: PressureCurve?
    var pressureSmoothing: Double?
    var smoothingMilliseconds: Double {
        get { pressureSmoothing ?? 12 }
        set { pressureSmoothing = newValue }
    }
    var contactThreshold = 10
    var pressureProfileID: UUID?
    // Profile payload is used in backups/imports; live profiles have individual JSON files.
    var pressureProfiles: [PressureProfile]?
    var customShortcuts: [String: CustomKeyShortcut]?
    subscript(shortcut key: String) -> CustomKeyShortcut? {
        get { customShortcuts?[key] }
        set {
            var shortcuts = customShortcuts ?? [:]
            shortcuts[key] = newValue
            customShortcuts = shortcuts.isEmpty ? nil : shortcuts
        }
    }
    var penButtons: [ButtonAction] = [.none, .none]
    // Index 0: ring center switch; 1...8: ExpressKeys.
    var tabletButtons = Array(repeating: ButtonAction.none, count: 9)

    // Optional storage keeps older version-1 settings/backups readable.
    var touchRing: RingSettings?
    var ringSettings: RingSettings {
        get { touchRing ?? RingSettings() }
        set { touchRing = newValue }
    }

    var surfaceTouch: TouchSettings?
    var touchSettings: TouchSettings {
        get { surfaceTouch ?? TouchSettings() }
        set { surfaceTouch = newValue }
    }

    static func validatePressure(sensitivity: Double, contactThreshold: Int) throws {
        guard sensitivity.isFinite, (0...1).contains(sensitivity), (0...2046).contains(contactThreshold) else {
            throw SettingsError.invalid("Pressure sensitivity or tip activation is outside its allowed range.")
        }
    }
    func validate() throws {
        try Self.validatePressure(sensitivity: sensitivity, contactThreshold: contactThreshold)
        try pressureCurve?.validate()
        guard smoothingMilliseconds.isFinite, (0...50).contains(smoothingMilliseconds) else {
            throw SettingsError.invalid("Pressure smoothing must be between 0 and 50 ms.")
        }
        if let profiles = pressureProfiles {
            guard Set(profiles.map(\.id)).count == profiles.count else { throw SettingsError.invalid("Duplicate pressure profile IDs.") }
            for profile in profiles { try profile.validate() }
        }
        guard version == 1 else { throw SettingsError.invalid("This settings version is not supported.") }
        guard penButtons.count == 2, tabletButtons.count == 9 else {
            throw SettingsError.invalid("Expected two pen buttons and nine tablet buttons.")
        }
        let bindings = [("pen", penButtons), ("tablet", tabletButtons)]
        let validKeys = Set(bindings.flatMap { prefix, actions in actions.indices.map { "\(prefix).\($0)" } })
        for (key, shortcut) in customShortcuts ?? [:] {
            guard validKeys.contains(key), shortcut.keyCode <= 126,
                  shortcut.modifiers & ~CustomKeyShortcut.allowedModifiers == 0,
                  !shortcut.label.isEmpty, shortcut.label.count <= 80 else {
                throw SettingsError.invalid("Invalid custom keyboard shortcut.")
            }
        }
        for (prefix, actions) in bindings {
            for (index, action) in actions.enumerated() where action == .customKey {
                guard self[shortcut: "\(prefix).\(index)"] != nil else {
                    throw SettingsError.invalid("Record a shortcut for each custom button before saving.")
                }
            }
        }
        guard touchSettings.pointerSpeed.isFinite, (0.25...4).contains(touchSettings.pointerSpeed) else {
            throw SettingsError.invalid("Touch pointer speed is outside its allowed range.")
        }
        guard (1...18).contains(ringSettings.stepsPerShortcut) else {
            throw SettingsError.invalid("Touch-ring response is outside its allowed range.")
        }
        guard [areaX, areaY, areaWidth, areaHeight].allSatisfy(\.isFinite),
              areaX >= 0, areaY >= 0, areaWidth >= 0.05, areaHeight >= 0.05,
              areaX + areaWidth <= 1.000001, areaY + areaHeight <= 1.000001,
              displayUUID.isEmpty || UUID(uuidString: displayUUID) != nil else {
            throw SettingsError.invalid("Mapping or sensitivity values are outside their allowed range.")
        }
    }

    func pressure(_ raw: Int) -> Double {
        let input = min(1, max(0, Double(raw) / 2047))
        return pressureCurve?.response(input) ?? pow(input, pow(4, 0.5 - sensitivity))
    }

    func activeArea(in bounds: CGRect) -> CGRect {
        var width = areaWidth, height = areaHeight
        if preserveAspect {
            let ratio = bounds.width / max(1, bounds.height)
            if width * 65024 / (height * 40640) > ratio { width = height * 40640 * ratio / 65024 }
            else { height = width * 65024 / ratio / 40640 }
        }
        let left = areaX + (areaWidth - width) / 2
        let top = areaY + (areaHeight - height) / 2
        return CGRect(x: left, y: top, width: width, height: height)
    }

    func location(x: Int, y: Int, bounds: CGRect) -> CGPoint {
        let area = activeArea(in: bounds)
        var nx = min(1, max(0, (Double(x) / 65024 - area.minX) / area.width))
        var ny = min(1, max(0, (Double(y) / 40640 - area.minY) / area.height))
        if rotate180 { nx = 1 - nx; ny = 1 - ny }
        return CGPoint(x: bounds.minX + nx * max(0, bounds.width - 1), y: bounds.minY + ny * max(0, bounds.height - 1))
    }

    var displayBounds: CGRect {
        if !displayUUID.isEmpty, let uuid = CFUUIDCreateFromString(nil, displayUUID as CFString) {
            let id = CGDisplayGetDisplayIDFromUUID(uuid)
            if id != kCGNullDirectDisplay, CGDisplayIsActive(id) != 0 { return CGDisplayBounds(id) }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }
}

enum SettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

struct SettingsFile {
    let url: URL
    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("WaccomDrive/settings.json")) { self.url = url }
    static func read(_ url: URL) throws -> DriverSettings {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw SettingsError.invalid("Settings files must be smaller than 1 MB.") }
        let settings = try JSONDecoder().decode(DriverSettings.self, from: Data(contentsOf: url))
        try settings.validate()
        return settings
    }
    static func write(_ settings: DriverSettings, to url: URL) throws {
        try settings.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
