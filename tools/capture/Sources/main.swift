import Foundation

// This recorder has no dependency on the app, its settings, or its input decoder.
enum CaptureError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

do {
    try HIDCapture.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
