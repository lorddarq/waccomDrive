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
    func validate() throws {
        guard keyCode <= 126, modifiers & ~Self.allowedModifiers == 0, !label.isEmpty, label.count <= 80 else {
            throw SettingsError.invalid("Invalid custom keyboard shortcut.")
        }
    }
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

struct PressureAnchor: Codable, Equatable {
    var input: Double
    var output: Double
}

struct EditablePressureCurve: Codable, Equatable {
    enum Interpolation: String, Codable, CaseIterable { case linear, smooth }
    var enabled = true
    var interpolation: Interpolation = .smooth
    var inverted = false
    var anchors = [PressureAnchor(input: 0, output: 0), PressureAnchor(input: 0.5, output: 0.5), PressureAnchor(input: 1, output: 1)]

    func inputRange(at index: Int) -> ClosedRange<Double> {
        if index == 0 || index == anchors.count - 1 { return anchors[index].input...anchors[index].input }
        return anchors[index - 1].input.nextUp...anchors[index + 1].input.nextDown
    }

    func outputRange(at index: Int) -> ClosedRange<Double> {
        let previous = index > 0 ? anchors[index - 1].output : (inverted ? 1 : 0)
        let next = index + 1 < anchors.count ? anchors[index + 1].output : (inverted ? 0 : 1)
        return min(previous, next)...max(previous, next)
    }

    func validate() throws {
        guard (2...8).contains(anchors.count), anchors.first?.input == 0, anchors.last?.input == 1,
              anchors.allSatisfy({ $0.input.isFinite && $0.output.isFinite && (0...1).contains($0.input) && (0...1).contains($0.output) }),
              zip(anchors, anchors.dropFirst()).allSatisfy({ a, b in
                  a.input < b.input && (inverted ? a.output >= b.output : a.output <= b.output)
              }) else {
            throw SettingsError.invalid("Use 2–8 anchors with unique increasing inputs from 0% to 100% and outputs ordered in the selected direction.")
        }
    }

    static func converting(_ settings: DriverSettings) -> Self {
        Self(anchors: [0.0, 0.25, 0.5, 0.75, 1].map {
            PressureAnchor(input: $0, output: settings.baselinePressureResponse($0))
        })
    }
}

// Piecewise cubic Hermite coefficients in normalized segment coordinates.
// Prepared once per settings change, never in the HID report path.
struct CompiledPressureCurve {
    private struct Segment {
        let x: Double, width: Double, a: Double, b: Double, c: Double, d: Double
        let low: Double, high: Double
    }
    private var segments: [Segment] = []
    private let first: Double
    private let last: Double

    init(_ curve: EditablePressureCurve) {
        precondition((try? curve.validate()) != nil)
        let points = curve.anchors
        first = points[0].output; last = points[points.count - 1].output
        let h = zip(points, points.dropFirst()).map { $1.input - $0.input }
        // Limit only astronomically small intervals to keep intermediate arithmetic finite.
        // Ordinary and close editable anchors retain their actual secants.
        let delta = h.indices.map { (points[$0 + 1].output - points[$0].output) / max(h[$0], 1e-150) }
        var slopes = Array(repeating: 0.0, count: points.count)
        if points.count == 2 { slopes = [delta[0], delta[0]] }
        else {
            func endpoint(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
                let ratio = h0 / (h0 + h1)
                let slope = (1 + ratio) * d0 - ratio * d1
                if slope * d0 <= 0 { return 0 }
                if d0 * d1 <= 0 && abs(slope) > 3 * abs(d0) { return 3 * d0 }
                return slope
            }
            slopes[0] = endpoint(h[0], h[1], delta[0], delta[1])
            slopes[points.count - 1] = endpoint(h[h.count - 1], h[h.count - 2], delta[delta.count - 1], delta[delta.count - 2])
            for i in 1..<(points.count - 1) where delta[i - 1] * delta[i] > 0 {
                let weight = (2 * h[i] + h[i - 1]) / (3 * (h[i] + h[i - 1]))
                let small = min(abs(delta[i - 1]), abs(delta[i]))
                let magnitude = small / (weight * small / abs(delta[i - 1]) + (1 - weight) * small / abs(delta[i]))
                slopes[i] = delta[i] > 0 ? magnitude : -magnitude
            }
        }
        for i in h.indices {
            let change = points[i + 1].output - points[i].output
            let m0 = h[i] * slopes[i], m1 = h[i] * slopes[i + 1]
            let smooth = curve.interpolation == .smooth
            segments.append(Segment(x: points[i].input, width: h[i],
                a: smooth ? m0 + m1 - 2 * change : 0,
                b: smooth ? 3 * change - 2 * m0 - m1 : 0,
                c: smooth ? m0 : change, d: points[i].output,
                low: min(points[i].output, points[i + 1].output), high: max(points[i].output, points[i + 1].output)))
        }
    }
    func response(_ input: Double) -> Double {
        guard input.isFinite else { return first }
        if input <= 0 { return first }
        if input >= 1 { return last }
        let segment = segments.first { input < $0.x + $0.width } ?? segments[segments.count - 1]
        let t = (input - segment.x) / segment.width
        return min(segment.high, max(segment.low, ((segment.a * t + segment.b) * t + segment.c) * t + segment.d))
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

enum PressureProcessingMode: String, Codable, CaseIterable, Identifiable {
    case bypass, fixed, sampleAndHold, movingAverage, ema
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bypass: "Bypass"
        case .fixed: "Fixed"
        case .sampleAndHold: "Sample and hold"
        case .movingAverage: "Moving average"
        case .ema: "EMA"
        }
    }
}

struct PressureProcessingSettings: Codable, Equatable {
    var enabled = false
    var mode: PressureProcessingMode = .ema
    var fixedValue = 0.5
    var sampleCount = 4
    var acquisitionMilliseconds = 30.0
    var windowMilliseconds = 12.0
    var emaMilliseconds = 12.0
    func validate() throws {
        guard fixedValue.isFinite, (0...1).contains(fixedValue),
              (1...64).contains(sampleCount),
              acquisitionMilliseconds.isFinite, (1...100).contains(acquisitionMilliseconds),
              windowMilliseconds.isFinite, (1...100).contains(windowMilliseconds),
              emaMilliseconds.isFinite, (0...50).contains(emaMilliseconds) else {
            throw SettingsError.invalid("Pressure processing parameters are outside their allowed ranges.")
        }
    }
}

struct PulledStringSettings: Codable, Equatable {
    var enabled = false
    var length = 12.0 // macOS logical screen points
    var showGuide: Bool?
    var guideVisible: Bool {
        get { showGuide ?? true }
        set { showGuide = newValue }
    }
    func validate() throws {
        guard length.isFinite, (0...500).contains(length) else {
            throw SettingsError.invalid("String length must be between 0 and 500 screen points.")
        }
    }
}

struct PressureSpeedSettings: Codable, Equatable {
    var enabled = false
    var slowSpeed = 0.0
    var fastSpeed = 1000.0
    var slowGain = 1.0
    var fastGain = 1.0
    var averagingMilliseconds = 0.0
    func validate() throws {
        guard [slowSpeed, fastSpeed, slowGain, fastGain, averagingMilliseconds].allSatisfy(\.isFinite),
              (0...10000).contains(slowSpeed), (0...10000).contains(fastSpeed), slowSpeed < fastSpeed,
              (0...4).contains(slowGain), (0...4).contains(fastGain),
              (0...100).contains(averagingMilliseconds) else {
            throw SettingsError.invalid("Speed thresholds must increase within 0–10,000 points/s, gains must be 0–4, and averaging must be 0–100 ms.")
        }
    }
    func gain(at speed: Double) -> Double {
        if slowGain == 1 && fastGain == 1 { return 1 }
        let fraction = min(1, max(0, (speed - slowSpeed) / (fastSpeed - slowSpeed)))
        return slowGain + fraction * (fastGain - slowGain)
    }
}

struct DriverSettings: Codable, Equatable {
    var version = 1
    var displayUUID = ""
    var preserveAspect = false
    var rotate180 = false
    var areaX = 0.0, areaY = 0.0, areaWidth = 1.0, areaHeight = 1.0
    var sensitivity = 0.5
    var pressureCurve: PressureCurve?
    var advancedPressureCurve: EditablePressureCurve?
    var dedicatedInputThread: Bool?
    var usesDedicatedInputThread: Bool {
        get { dedicatedInputThread ?? true }
        set { dedicatedInputThread = newValue }
    }
    var advancedFeatures: Bool?
    var advancedFeaturesEnabled: Bool {
        get { advancedFeatures ?? false }
        set { advancedFeatures = newValue }
    }
    var ruler: RulerSettings?
    var rulerSettings: RulerSettings {
        get { ruler ?? RulerSettings() }
        set { ruler = newValue }
    }
    var pressureSpeed: PressureSpeedSettings?
    var speedSettings: PressureSpeedSettings {
        get { pressureSpeed ?? PressureSpeedSettings() }
        set { pressureSpeed = newValue }
    }
    var pulledString: PulledStringSettings?
    var stringSettings: PulledStringSettings {
        get { pulledString ?? PulledStringSettings() }
        set { pulledString = newValue }
    }
    var pressureProcessing: PressureProcessingSettings?
    var processingSettings: PressureProcessingSettings {
        get { pressureProcessing ?? PressureProcessingSettings() }
        set { pressureProcessing = newValue }
    }
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
    var rulerPickerShortcut: CustomKeyShortcut?
    var rulerPickerShortcutDisabled: Bool?
    var pickerShortcut: CustomKeyShortcut? {
        get {
            rulerPickerShortcutDisabled == true ? nil : (rulerPickerShortcut ?? CustomKeyShortcut(keyCode: 15,
                modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue, label: "⌃⌥R"))
        }
        set { rulerPickerShortcut = newValue; rulerPickerShortcutDisabled = newValue == nil }
    }
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
        try advancedPressureCurve?.validate()
        try pressureProcessing?.validate()
        try pulledString?.validate()
        try pressureSpeed?.validate()
        try ruler?.validate()
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
            guard validKeys.contains(key) else {
                throw SettingsError.invalid("Invalid custom keyboard shortcut.")
            }
            try shortcut.validate()
        }
        if let shortcut = rulerPickerShortcut {
            try shortcut.validate()
            let modifiers = CGEventFlags(rawValue: shortcut.modifiers)
            guard !modifiers.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty,
                  ![51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 115, 123, 124, 125, 126].contains(shortcut.keyCode) else {
                throw SettingsError.invalid("Choose Control, Option or Command plus a non-navigation key for the ruler picker.")
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
        if advancedFeaturesEnabled, let curve = advancedPressureCurve, curve.enabled {
            return CompiledPressureCurve(curve).response(input)
        }
        return baselinePressureResponse(input)
    }

    func baselinePressureResponse(_ input: Double) -> Double {
        pressureCurve?.response(input) ?? pow(input, pow(4, 0.5 - sensitivity))
    }

    func activeArea(in bounds: CGRect, tabletSize: CGSize = SupportedTablet.large.penSize) -> CGRect {
        var width = areaWidth, height = areaHeight
        if preserveAspect {
            let ratio = bounds.width / max(1, bounds.height)
            if width * tabletSize.width / (height * tabletSize.height) > ratio { width = height * tabletSize.height * ratio / tabletSize.width }
            else { height = width * tabletSize.width / ratio / tabletSize.height }
        }
        let left = areaX + (areaWidth - width) / 2
        let top = areaY + (areaHeight - height) / 2
        return CGRect(x: left, y: top, width: width, height: height)
    }

    func location(x: Int, y: Int, bounds: CGRect, tabletSize: CGSize = SupportedTablet.large.penSize) -> CGPoint {
        let area = activeArea(in: bounds, tabletSize: tabletSize)
        var nx = min(1, max(0, (Double(x) / tabletSize.width - area.minX) / area.width))
        var ny = min(1, max(0, (Double(y) / tabletSize.height - area.minY) / area.height))
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
