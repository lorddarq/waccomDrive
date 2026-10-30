import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot decode installer cover") }
// Fill the Introduction pane at Retina resolution; crop overflow without stretching.
let size = NSSize(width: 400, height: 310)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 620,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let scale = max(size.width / image.size.width, size.height / image.size.height)
let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
image.draw(in: NSRect(x: 0, y: (size.height - drawn.height) / 2,
                      width: drawn.width, height: drawn.height))
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
let wrapper = FileWrapper(regularFileWithContents: png)
wrapper.preferredFilename = "Cover.png"
let attachment = NSTextAttachment(fileWrapper: wrapper)
let document = NSAttributedString(attachment: attachment)
let range = NSRange(location: 0, length: document.length)
let checkOnly = CommandLine.arguments.dropFirst(3).first == "--check"
if !checkOnly {
    let rtfd = try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    try rtfd.write(to: destination, options: .atomic)
}
// Check decoded pixels and display size, not merely the presence of an attachment.
let restored = try NSAttributedString(data: Data(contentsOf: destination), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
let restoredAttachment = restored.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
let restoredData = restoredAttachment.fileWrapper!.regularFileContents!
guard restoredData == png, let restoredImage = NSImage(data: restoredData), restoredImage.size == size else {
    throw NSError(domain: "Installer welcome artwork does not match the expected image and crop", code: 1)
}
