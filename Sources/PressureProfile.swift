import Foundation
import CoreGraphics

enum DrawingPresetScope: String, Codable, CaseIterable, Identifiable {
    case basic, position, pressure, curve, ruler, speed, combined, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All drawing settings"
        case .basic: "Basic pressure"
        case .position: "Position smoothing"
        case .pressure: "Pressure processing"
        case .curve: "Response curve"
        case .ruler: "Ruler geometry and appearance"
        case .speed: "Speed scaling"
        case .combined: "Combined advanced drawing"
        }
    }
    func includes(_ section: Self) -> Bool { self == .all || self == section || self == .combined && section != .basic }
}

// Display coordinates are logical points. Remapping runs on the settings owner,
// never on the report-processing owner.
struct PresetDisplay: Codable, Equatable {
    var uuid: String
    var bounds: CGRect
    func validate() throws {
        guard UUID(uuidString: uuid) != nil,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
              bounds.width >= 1, bounds.height >= 1 else { throw SettingsError.invalid("Invalid preset display reference.") }
    }
}

struct DrawingPreset: Codable, Equatable {
    var scope: DrawingPresetScope
    var position: PulledStringSettings?
    var pressure: PressureProcessingSettings?
    var curve: EditablePressureCurve?
    var ruler: RulerSettings?
    var speed: PressureSpeedSettings?
    var display: PresetDisplay?
    init(scope: DrawingPresetScope, settings: DriverSettings, display: PresetDisplay? = nil) {
        self.scope = scope
        if scope.includes(.position) { position = settings.stringSettings }
        if scope.includes(.pressure) { pressure = settings.processingSettings }
        if scope.includes(.curve) { curve = settings.advancedPressureCurve }
        if scope.includes(.ruler) { ruler = settings.rulerSettings; self.display = display }
        if scope.includes(.speed) { speed = settings.speedSettings }
    }
    func validate() throws {
        guard scope != .basic,
              scope.includes(.position) || position == nil,
              scope.includes(.pressure) || pressure == nil,
              scope.includes(.curve) || curve == nil,
              scope.includes(.ruler) || ruler == nil && display == nil,
              scope.includes(.speed) || speed == nil else { throw SettingsError.invalid("Preset payload does not match its section scope.") }
        try position?.validate(); try pressure?.validate(); try curve?.validate()
        try ruler?.validate(); try speed?.validate(); try display?.validate()
    }
    func apply(to settings: inout DriverSettings) {
        if scope.includes(.position) { settings.pulledString = position }
        if scope.includes(.pressure) { settings.pressureProcessing = pressure }
        if scope.includes(.curve) { settings.advancedPressureCurve = curve }
        if scope.includes(.ruler) { settings.ruler = ruler }
        if scope.includes(.speed) { settings.pressureSpeed = speed }
    }
    // Translation preserves sizes, angles and projective geometry. A missing or
    // rearranged display centers the construction on a usable active display.
    func remapped(to displays: [PresetDisplay]) throws -> (DrawingPreset, Bool) {
        guard let ruler, !displays.isEmpty else { return (self, false) }
        if display == nil, displays.contains(where: { $0.bounds.contains(ruler.editingCenter) }) { return (self, false) }
        let target = displays.first { $0.uuid == display?.uuid } ?? displays[0]
        guard display != target else { return (self, false) }
        var result = self
        let origin = ruler.editingCenter
        let desired: CGPoint
        if let display, displays.contains(where: { $0.uuid == display.uuid }) {
            desired = CGPoint(x: target.bounds.minX + min(0.95, max(0.05, (origin.x - display.bounds.minX) / display.bounds.width)) * target.bounds.width,
                              y: target.bounds.minY + min(0.95, max(0.05, (origin.y - display.bounds.minY) / display.bounds.height)) * target.bounds.height)
        } else { desired = CGPoint(x: target.bounds.midX, y: target.bounds.midY) }
        let delta = CGPoint(x: desired.x - origin.x, y: desired.y - origin.y)
        func translated(_ point: RulerPoint) -> RulerPoint { RulerPoint(x: point.x + delta.x, y: point.y + delta.y) }
        var moved = ruler
        moved.centerX += delta.x; moved.centerY += delta.y
        moved.corners = moved.corners.map(translated); moved.vanishingPoints = moved.vanishingPoints.map(translated)
        moved.sceneLines = moved.sceneLines?.map { $0.map(translated) }
        moved.fixedReference = moved.fixedReference.map(translated)
        if var depth = moved.ellipseDepth {
            depth.vanishingPoint = translated(depth.vanishingPoint)
            depth.sceneLines = depth.sceneLines?.map(translated); moved.ellipseDepth = depth
        }
        if moved.construction != nil || moved.kind == .straight {
            moved.constructionSettings.start = translated(moved.constructionSettings.start)
            moved.constructionSettings.end = translated(moved.constructionSettings.end)
        }
        try moved.validate()
        result.ruler = moved; result.display = target
        try result.validate()
        return (result, true)
    }
}

struct PressureProfile: Codable, Equatable, Identifiable {
    var version = 1
    var id = UUID()
    var name: String
    var sensitivity: Double
    var contactThreshold: Int
    var pressureCurve: PressureCurve?
    var pressureSmoothing: Double?
    var advancedPressureCurve: EditablePressureCurve?
    var drawing: DrawingPreset?
    var scope: DrawingPresetScope { drawing?.scope ?? .basic }
    static func capture(name: String, scope: DrawingPresetScope = .all, settings: DriverSettings, display: PresetDisplay? = nil) -> Self {
        var profile = Self(name: name, sensitivity: settings.sensitivity, contactThreshold: settings.contactThreshold,
                           pressureCurve: settings.pressureCurve, pressureSmoothing: settings.pressureSmoothing,
                           advancedPressureCurve: settings.advancedPressureCurve)
        if scope != .basic {
            profile.version = 2
            profile.drawing = DrawingPreset(scope: scope, settings: settings, display: display)
            // Legacy fields remain decodable but never affect scoped activation.
            if scope != .all {
                profile.sensitivity = 0.5; profile.contactThreshold = 10
                profile.pressureCurve = nil; profile.pressureSmoothing = nil
            }
            profile.advancedPressureCurve = nil
        }
        return profile
    }
    func matches(_ settings: DriverSettings) -> Bool {
        if let drawing {
            if drawing.scope == .all, sensitivity != settings.sensitivity || contactThreshold != settings.contactThreshold ||
                pressureCurve != settings.pressureCurve || (pressureSmoothing ?? 12) != settings.smoothingMilliseconds { return false }
            var stored = DriverSettings(); drawing.apply(to: &stored)
            return DrawingPreset(scope: drawing.scope, settings: stored) == DrawingPreset(scope: drawing.scope, settings: settings)
        }
        return sensitivity == settings.sensitivity && contactThreshold == settings.contactThreshold && pressureCurve == settings.pressureCurve &&
            (pressureSmoothing ?? 12) == settings.smoothingMilliseconds && advancedPressureCurve == settings.advancedPressureCurve
    }

    func validate() throws {
        guard (version == 1 && drawing == nil || version == 2 && drawing != nil), (1...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
            throw SettingsError.invalid("Pressure profile names must contain 1–80 characters and use supported format version 1 or 2.")
        }
        try drawing?.validate()
        try DriverSettings.validatePressure(sensitivity: sensitivity, contactThreshold: contactThreshold)
        try pressureCurve?.validate()
        try advancedPressureCurve?.validate()
        if let pressureSmoothing, !pressureSmoothing.isFinite || !(0...50).contains(pressureSmoothing) {
            throw SettingsError.invalid("Pressure smoothing must be between 0 and 50 ms.")
        }
    }
    func apply(to settings: inout DriverSettings) {
        if let drawing {
            if drawing.scope == .all {
                settings.sensitivity = sensitivity; settings.contactThreshold = contactThreshold
                settings.pressureCurve = pressureCurve; settings.pressureSmoothing = pressureSmoothing
            }
            drawing.apply(to: &settings); settings.pressureProfileID = id; return
        }
        settings.sensitivity = sensitivity
        settings.pressureCurve = pressureCurve
        settings.advancedPressureCurve = advancedPressureCurve
        settings.pressureSmoothing = pressureSmoothing
        settings.contactThreshold = contactThreshold
        settings.pressureProfileID = id
    }
    static func next(in profiles: [PressureProfile], after id: UUID?) -> PressureProfile? {
        let ordered = sorted(profiles)
        guard !ordered.isEmpty else { return nil }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return ordered[0] }
        return ordered[(index + 1) % ordered.count]
    }
    static func sorted(_ profiles: [Self]) -> [Self] {
        profiles.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

}

struct PressureProfileStore {
    let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("WaccomDrive/PressureProfiles")) {
        self.directory = directory
    }
    func load() throws -> [PressureProfile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try PressureProfile.sorted(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                let profile = try Self.read(url)
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == profile.id else {
                    throw SettingsError.invalid("Profile ID does not match its filename: \(url.lastPathComponent)")
                }
                return profile
            })
    }
    static func read(_ url: URL) throws -> PressureProfile {
        let profile = try JSONDecoder().decode(PressureProfile.self, from: SettingsFile.readData(url))
        try profile.validate()
        return profile
    }
    func save(_ profile: PressureProfile) throws {
        try profile.validate()
        try SettingsFile.writeJSON(profile, to: directory.appendingPathComponent(profile.id.uuidString + ".json"))
    }
    // Validate and serialize the entire import before touching files. Keep exact
    // prior bytes so a later filesystem/settings failure rolls back earlier writes.
    func save(_ profiles: [PressureProfile], settings: DriverSettings, to settingsURL: URL) throws {
        try settings.validate()
        if profiles.isEmpty { try SettingsFile.write(settings, to: settingsURL); return }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw SettingsError.invalid("Duplicate profile IDs.") }
        var writes: [(URL, Data)] = try profiles.map { profile in
            try profile.validate()
            return (directory.appendingPathComponent(profile.id.uuidString + ".json"), try SettingsFile.jsonData(profile))
        }
        writes.append((settingsURL, try SettingsFile.jsonData(settings)))
        let originals: [Data?] = try writes.map { url, _ in
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            return try SettingsFile.readData(url)
        }
        let recovery = directory.appendingPathComponent(".restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        var keepRecovery = false
        defer { if !keepRecovery { try? FileManager.default.removeItem(at: recovery) } }
        try SettingsFile.writeJSON(writes.map { $0.0.path }, to: recovery.appendingPathComponent("destinations.json"))
        for i in originals.indices {
            if let data = originals[i] { try SettingsFile.writeData(data, to: recovery.appendingPathComponent("\(i).bak")) }
        }
        var completed = 0
        do {
            for (url, data) in writes {
                try SettingsFile.writeData(data, to: url); completed += 1
            }
        } catch {
            let failure = error
            do {
                for i in (0..<completed).reversed() {
                    if let data = originals[i] { try SettingsFile.writeData(data, to: writes[i].0) }
                    else { try FileManager.default.removeItem(at: writes[i].0) }
                }
            } catch {
                keepRecovery = true
                throw SettingsError.invalid("Import failed: \(failure.localizedDescription). Rollback failed: \(error.localizedDescription). Original bytes and destination list are retained at \(recovery.path).")
            }
            throw failure
        }
    }
    func delete(_ id: UUID) throws {
        try FileManager.default.trashItem(at: directory.appendingPathComponent(id.uuidString + ".json"), resultingItemURL: nil)
    }
}
