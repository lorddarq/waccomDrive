import Foundation

struct PressureProfile: Codable, Equatable, Identifiable {
    var version = 1
    var id = UUID()
    var name: String
    var sensitivity: Double
    var contactThreshold: Int

    func validate() throws {
        guard version == 1, (1...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
            throw SettingsError.invalid("Pressure profile names must contain 1–80 characters and use format version 1.")
        }
        try DriverSettings.validatePressure(sensitivity: sensitivity, contactThreshold: contactThreshold)
    }
    func apply(to settings: inout DriverSettings) {
        settings.sensitivity = sensitivity
        settings.contactThreshold = contactThreshold
        settings.pressureProfileID = id
    }
    static func next(in profiles: [PressureProfile], after id: UUID?) -> PressureProfile? {
        guard !profiles.isEmpty else { return nil }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return profiles[0] }
        return profiles[(index + 1) % profiles.count]
    }
}

struct PressureProfileStore {
    let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("WaccomDrive/PressureProfiles")) {
        self.directory = directory
    }
    func load() throws -> [PressureProfile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.map { url in
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else {
                    throw SettingsError.invalid("Pressure profile exceeds 1 MB: \(url.lastPathComponent)")
                }
                let profile = try JSONDecoder().decode(PressureProfile.self, from: Data(contentsOf: url))
                try profile.validate()
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == profile.id else {
                    throw SettingsError.invalid("Pressure profile ID does not match its filename: \(url.lastPathComponent)")
                }
                return profile
            }.sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func save(_ profile: PressureProfile) throws {
        try profile.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(profile.id.uuidString + ".json"), options: .atomic)
    }
    func delete(_ id: UUID) throws {
        try FileManager.default.trashItem(at: directory.appendingPathComponent(id.uuidString + ".json"), resultingItemURL: nil)
    }
}
