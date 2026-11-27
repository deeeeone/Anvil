// Renders the three Discord Rich Presence status badges (128x128): working, thinking, idle.
// swift design/presence/make_badges.swift <out-dir>
import AppKit

let size = 128
let coral = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
let slate = NSColor(srgbRed: 0x3F / 255, green: 0x3F / 255, blue: 0x46 / 255, alpha: 1)

/// An SF Symbol drawn in white at the given point size.
func whiteSymbol(_ name: String, points: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let sym = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)) else { return nil }
    let rect = NSRect(origin: .zero, size: sym.size)
    let out = NSImage(size: sym.size)
    out.lockFocus()
    sym.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func badge(_ color: NSColor, draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let circle = NSBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size))
    color.set()
    circle.fill()
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawSymbol(_ name: String, in r: CGRect, points: CGFloat) {
    guard let img = whiteSymbol(name, points: points) else { fatalError("missing symbol \(name)") }
    let s = img.size
    let scale = min(r.width * 0.55 / s.width, r.height * 0.55 / s.height)
    let w = s.width * scale, h = s.height * scale
    img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outputs: [(String, NSBitmapImageRep)] = [
    ("working", badge(coral) { r in drawSymbol("hammer.fill", in: r, points: 80) }),
    ("thinking", badge(coral) { r in
        // Three white dots.
        NSColor.white.set()
        let d: CGFloat = 16, gap: CGFloat = 12
        let total = 3 * d + 2 * gap
        for i in 0..<3 {
            let x = r.midX - total / 2 + CGFloat(i) * (d + gap)
            NSBezierPath(ovalIn: CGRect(x: x, y: r.midY - d / 2, width: d, height: d)).fill()
        }
    }),
    ("idle", badge(slate) { r in drawSymbol("moon.fill", in: r, points: 80) }),
]
for (name, rep) in outputs {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}
