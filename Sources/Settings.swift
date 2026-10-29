import Foundation
import CoreGraphics
import ColorSync

enum ButtonAction: String, Codable, CaseIterable, Identifiable {
    case none, rightClick, middleClick, undo, redo, brush, eraser, brushSmaller, brushLarger, space, shift, option, command, control
    var id: String { rawValue }
    var title: String {
        switch self {
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
        }
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
    var contactThreshold = 10
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

    func validate() throws {
        guard version == 1 else { throw SettingsError.invalid("This settings version is not supported.") }
        guard penButtons.count == 2, tabletButtons.count == 9 else {
            throw SettingsError.invalid("Expected two pen buttons and nine tablet buttons.")
        }
        guard touchSettings.pointerSpeed.isFinite, (0.25...4).contains(touchSettings.pointerSpeed) else {
            throw SettingsError.invalid("Touch pointer speed is outside its allowed range.")
        }
        guard (1...18).contains(ringSettings.stepsPerShortcut) else {
            throw SettingsError.invalid("Touch-ring response is outside its allowed range.")
        }
        guard sensitivity.isFinite, (0...1).contains(sensitivity), (0...2046).contains(contactThreshold),
              [areaX, areaY, areaWidth, areaHeight].allSatisfy(\.isFinite),
              areaX >= 0, areaY >= 0, areaWidth >= 0.05, areaHeight >= 0.05,
              areaX + areaWidth <= 1.000001, areaY + areaHeight <= 1.000001,
              displayUUID.isEmpty || UUID(uuidString: displayUUID) != nil else {
            throw SettingsError.invalid("Mapping or sensitivity values are outside their allowed range.")
        }
    }

    func pressure(_ raw: Int) -> Double {
        pow(min(1, max(0, Double(raw) / 2047)), pow(4, 0.5 - sensitivity))
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
