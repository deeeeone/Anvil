// Renders Anvil's logo: a coral anvil with a spark on a deep black rounded square.
// swift make_icon.swift <out-dir>
import AppKit

func anvilPath(in r: CGRect) -> NSBezierPath {
    // Coordinates on a 100x100 grid, y up.
    let s = r.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }
    let path = NSBezierPath()
    // Top face with the horn on the left.
    path.move(to: p(12, 62))
    path.curve(to: p(30, 54), controlPoint1: p(20, 61), controlPoint2: p(26, 57))
    path.line(to: p(36, 54))
    // Waist down to the base.
    path.curve(to: p(42, 38), controlPoint1: p(40, 50), controlPoint2: p(42, 44))
    path.line(to: p(34, 30))
    path.line(to: p(30, 30))
    path.line(to: p(30, 22))
    path.line(to: p(74, 22))
    path.line(to: p(74, 30))
    path.line(to: p(70, 30))
    path.line(to: p(62, 38))
    path.curve(to: p(68, 54), controlPoint1: p(62, 44), controlPoint2: p(64, 50))
    path.line(to: p(84, 54))
    path.line(to: p(84, 66))
    path.line(to: p(26, 66))
    path.curve(to: p(12, 62), controlPoint1: p(20, 66), controlPoint2: p(15, 64.5))
    path.close()
    return path
}

func sparkPath(center c: NSPoint, size: CGFloat) -> NSBezierPath {
    // Four-point star.
    let path = NSBezierPath()
    let a = size, b = size * 0.22
    path.move(to: NSPoint(x: c.x, y: c.y + a))
    path.curve(to: NSPoint(x: c.x + a, y: c.y), controlPoint1: NSPoint(x: c.x + b, y: c.y + b), controlPoint2: NSPoint(x: c.x + b, y: c.y + b))
    path.curve(to: NSPoint(x: c.x, y: c.y - a), controlPoint1: NSPoint(x: c.x + b, y: c.y - b), controlPoint2: NSPoint(x: c.x + b, y: c.y - b))
    path.curve(to: NSPoint(x: c.x - a, y: c.y), controlPoint1: NSPoint(x: c.x - b, y: c.y - b), controlPoint2: NSPoint(x: c.x - b, y: c.y - b))
    path.curve(to: NSPoint(x: c.x, y: c.y + a), controlPoint1: NSPoint(x: c.x - b, y: c.y + b), controlPoint2: NSPoint(x: c.x - b, y: c.y + b))
    path.close()
    return path
}

func render(_ px: Int, background: Bool) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let coral = NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
    let coralLight = NSColor(srgbRed: 0xF0/255, green: 0x9A/255, blue: 0x7A/255, alpha: 1)
    var art = CGRect(x: 0, y: 0, width: size, height: size)
    if background {
        // macOS icon grid: the rounded square sits inside ~10% padding.
        let inset = size * 0.1
        let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = size * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.047, alpha: 1).setFill(); tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Subtle top sheen and a faint warm glow behind the anvil.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)])!.draw(in: tilePath, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        let c = NSPoint(x: tile.midX, y: tile.midY + tile.height * 0.02)
        NSGradient(colors: [coral.withAlphaComponent(0.22), coral.withAlphaComponent(0.06), coral.withAlphaComponent(0)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: tile.width * 0.48, options: [])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        NSBezierPath(roundedRect: tile.insetBy(dx: size * 0.002, dy: size * 0.002), xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).stroke()
        art = tile.insetBy(dx: tile.width * 0.1, dy: tile.width * 0.1)
    }
    let anvil = anvilPath(in: art)
    NSGradient(colors: [coralLight, coral])!.draw(in: anvil, angle: -90)
    // Spark above the face, struck from the anvil.
    let s = art.width / 100
    let spark = sparkPath(center: NSPoint(x: art.minX + 58 * s, y: art.minY + 81 * s), size: 9 * s)
    NSColor(srgbRed: 1, green: 0.86, blue: 0.62, alpha: 1).setFill(); spark.fill()
    let small = sparkPath(center: NSPoint(x: art.minX + 71 * s, y: art.minY + 75 * s), size: 4 * s)
    coralLight.setFill(); small.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = out.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc, background: true).write(to: set.appendingPathComponent(name))
        images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(sc)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: set.appendingPathComponent("Contents.json"))
try! JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted]).write(to: out.appendingPathComponent("Contents.json"))
// The mark alone (transparent), for the app's own UI and the README.
let mark = out.appendingPathComponent("Logo.imageset")
try? FileManager.default.createDirectory(at: mark, withIntermediateDirectories: true)
try! render(256, background: false).write(to: mark.appendingPathComponent("logo.png"))
try! render(512, background: false).write(to: mark.appendingPathComponent("logo@2x.png"))
try! JSONSerialization.data(withJSONObject: ["images": [["idiom": "universal", "filename": "logo.png", "scale": "1x"], ["idiom": "universal", "filename": "logo@2x.png", "scale": "2x"]], "info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted]).write(to: mark.appendingPathComponent("Contents.json"))
try! render(1024, background: true).write(to: URL(fileURLWithPath: "/Users/diwan/Anvil/design/anvil-icon-1024.png"))
print("ok")
