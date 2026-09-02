// Watches whether the HUD pill is *actually* on screen. Run it (`swift Tools/hudwatch.swift`),
// dictate, and read the lines: every session must print an ONSCREEN line with alpha 1.00
// that lasts until the pill is dismissed. This exists because the "mic records but there's
// no pill" bug can't be observed from inside the app — `NSWindow.isVisible` and
// `alphaValue` both read as "shown" while the window server disagrees, so the check has to
// come from outside the process.
//
import CoreGraphics
import Foundation

// Samples what the *window server* thinks is on screen — the only witness that can't be
// fooled by the panel's own isVisible/alphaValue, which is exactly what the missing-pill
// bug lies about. Prints one line per change.
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
var last = ""
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "") ?? 180)
while Date() < deadline {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let hud = list.first { w in
        (w[kCGWindowOwnerName as String] as? String)?.contains("Murmur") == true
            && (w[kCGWindowLayer as String] as? Int ?? 0) > 0
    }
    let now: String
    if let hud {
        let b = hud[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let alpha = hud[kCGWindowAlpha as String] as? Double ?? -1
        now = "ONSCREEN alpha=\(String(format: "%.2f", alpha)) x=\(Int(b["X"] ?? -1)) y=\(Int(b["Y"] ?? -1)) w=\(Int(b["Width"] ?? -1)) h=\(Int(b["Height"] ?? -1))"
    } else {
        now = "absent"
    }
    if now != last { print(fmt.string(from: Date()), now); fflush(stdout); last = now }
    usleep(200_000)
}
