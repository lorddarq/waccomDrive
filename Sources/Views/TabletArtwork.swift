#if APP
import SwiftUI
import AppKit

// Assets stay in their exported coordinate systems; the app never stretches them.
@MainActor
enum TabletArtwork {
    private struct Catalog: Decodable {
        struct Model: Decodable { let id: String; let images: [String: String?] }
        let schema_version: Int
        let models: [Model]
    }
    private static let folder = Bundle.main.resourceURL!.appendingPathComponent("assets/tablet")
    private static let paths: [String: String?] = {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("models.json")),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.schema_version == 1 else { return [:] }
        return catalog.models.first { $0.id == "pth-851" }?.images ?? [:]
    }()
    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["base", "overlay", "express_keys", "mapping_faces", "mapping_strokes"] {
            if let path = paths[name] ?? nil, let image = NSImage(contentsOf: folder.appendingPathComponent(path)) {
                result[name] = image
            }
        }
        return result
    }()
    static func image(_ name: String) -> NSImage? { images[name] }
    private static func loadIcons(_ directory: String, names: [String]) -> [String: NSImage] {
        let directoryURL = folder.deletingLastPathComponent().appendingPathComponent(directory)
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            NSImage(contentsOf: directoryURL.appendingPathComponent(name + ".svg")).map { (name, $0) }
        })
    }
    private static let connections = loadIcons("connection", names: ["usb", "bluetooth-on", "bluetooth-off", "wifi-full", "wifi-half", "wifi-low", "wifi-off"])
    private static let batteries = loadIcons("battery", names: ["battery-status-10", "battery-status-20", "battery-status-50", "battery-status-80", "battery-status-full", "battery-status-charging", "battery-status-10-1"])
    static func connectionImage(_ name: String) -> NSImage? { connections[name] }
    static func batteryImage(_ name: String) -> NSImage? { batteries[name] }


    // Keep the source SVG intact. Isolate each overlay in a private copy,
    // preserving its curves, clipping, and original registration with the base.
    private static let overlays: [NSImage] = {
        guard let path = paths["overlay"] ?? nil else { return [] }
        return (0..<10).compactMap { target in
            guard let document = try? XMLDocument(contentsOf: folder.appendingPathComponent(path)),
                  let group = document.rootElement()?.elements(forName: "g").first else { return nil }
            var index = 0
            for child in group.children ?? [] {
                guard let element = child as? XMLElement else { continue }
                let isOverlay = element.attribute(forName: "fill")?.stringValue == "#007AFF"
                if !isOverlay || index != target {
                    element.detach()
                }
                if isOverlay { index += 1 }
            }
            guard index == 10 else { return nil }
            return NSImage(data: document.xmlData)
        }
    }()
    static func keyOverlay(_ key: Int) -> NSImage? {
        let index = key == 0 ? 9 : key - 1
        return overlays.indices.contains(index) ? overlays[index] : nil
    }
    static var ringOverlay: NSImage? { overlays.indices.contains(8) ? overlays[8] : nil }

}

struct TabletAsset: View {
    let name: String
    var body: some View {
        if let image = TabletArtwork.image(name) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "rectangle.landscape").resizable().scaledToFit()
                .foregroundStyle(.secondary).accessibilityLabel("Tablet artwork unavailable")
        }
    }
}
#endif
