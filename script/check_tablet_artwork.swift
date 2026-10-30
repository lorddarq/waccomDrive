// Compile alongside Sources/Views/TabletArtwork.swift with -D APP inside a test app bundle.
import AppKit

@main
struct ArtworkCheck {
    @MainActor static func main() {
        for name in ["base", "express_keys", "overlay", "mapping_faces", "mapping_strokes"] {
            guard let image = TabletArtwork.image(name) else { fatalError("Missing artwork: \(name)") }
            precondition(image.size.width > 0 && image.size.height > 0)
        }
        for name in ["usb", "bluetooth-on", "bluetooth-off", "wifi-full", "wifi-half", "wifi-low", "wifi-off"] {
            precondition(TabletArtwork.connectionImage(name) != nil, "Missing connector SVG: \(name)")
        }
        for name in ["battery-status-10", "battery-status-20", "battery-status-50", "battery-status-80", "battery-status-full", "battery-status-charging", "battery-status-10-1"] {
            precondition(TabletArtwork.batteryImage(name) != nil, "Missing battery SVG: \(name)")
        }
        for key in 0...8 {
            guard let image = TabletArtwork.keyOverlay(key),
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else { fatalError("Missing overlay \(key)") }
            precondition(image.size == NSSize(width: 479, height: 264))
            // Every isolated layer must be transparent outside its target.
            let scaleX = Double(bitmap.pixelsWide) / 479
            let scaleY = Double(bitmap.pixelsHigh) / 264
            let tops = [22.0, 42, 61, 80, 184, 203, 222, 242]
            for probe in 1...8 {
                let color = bitmap.colorAt(x: Int(46 * scaleX), y: Int(tops[probe - 1] * scaleY))!
                precondition((color.alphaComponent > 0.5) == (probe == key), "Overlay \(key) leaks into key \(probe)")
            }
            let center = bitmap.colorAt(x: Int(46 * scaleX), y: Int(132 * scaleY))!
            precondition((center.alphaComponent > 0.5) == (key == 0), "Center overlay registration")
        }
        guard let ring = TabletArtwork.ringOverlay,
              let data = ring.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { fatalError("Missing ring overlay") }
        let sx = Double(bitmap.pixelsWide) / 479, sy = Double(bitmap.pixelsHigh) / 264
        precondition(bitmap.colorAt(x: Int(20 * sx), y: Int(132 * sy))!.alphaComponent > 0.5)
        precondition(bitmap.colorAt(x: Int(46 * sx), y: Int(132 * sy))!.alphaComponent < 0.01)
        print("Native SVG loading and nine isolated key overlays passed.")
    }
}
