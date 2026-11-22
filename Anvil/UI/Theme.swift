import SwiftUI
import AppKit

/// Anvil's look: deep blacks, soft rounded surfaces, one warm accent.
enum Theme {
    static let window = Color(hex: 0x09090B)      // conversation background
    static let sidebar = Color(hex: 0x000000)     // pure black rail
    static let panel = Color(hex: 0x0D0D10)       // inspector
    static let surface = Color(hex: 0x141417)     // cards, composer
    static let surface2 = Color(hex: 0x1C1C21)    // raised: user messages, selected rows, pills
    static let hover = Color(hex: 0x18181C)
    static let code = Color(hex: 0x050506)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.12)

    static let text = Color(hex: 0xEDEDEF)
    static let text2 = Color(hex: 0xA1A1AA)
    static let text3 = Color(hex: 0x63636D)

    static let accent = Color(hex: 0xD97757)      // warm coral
    static let green = Color(hex: 0x4ADE80)
    static let red = Color(hex: 0xF87171)
    static let amber = Color(hex: 0xFBBF24)
    static let blue = Color(hex: 0x60A5FA)

    static let radius: CGFloat = 14
    static let topBar: CGFloat = 52
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Rounded pill buttons.
struct Pill: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .primary: return (Theme.accent, .white)
            case .secondary: return (Theme.surface2, Theme.text)
            case .ghost: return (.clear, Theme.text2)
            case .danger: return (Theme.red.opacity(0.15), Theme.red)
            }
        }()
        return configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 4 : 7)
            .background(bg.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .overlay(Capsule().stroke(kind == .ghost ? Theme.border : .clear))
            .foregroundStyle(fg)
            .contentShape(Capsule())
    }
}

/// A square icon button with a soft hover.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .frame(width: size, height: size)
                .background(hover ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A row that highlights on hover and when selected.
struct HoverRow<Content: View>: View {
    var selected = false
    let content: Content
    @State private var hover = false
    init(selected: Bool = false, @ViewBuilder content: () -> Content) { self.selected = selected; self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.surface2 : hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// Claude Code's working glyph, cycling.
/// A label that updates itself on a timer inside AppKit. SwiftUI's TimelineView re-runs layout up through the whole
/// window on every tick, which on a long conversation keeps the main thread busy for as long as a task runs
/// (and hung a beta tester's Mac). Here SwiftUI is never told about the ticks; it is only told when the label's
/// width really changes (for the elapsed timer, when it gains a digit).
struct TickingLabel: NSViewRepresentable {
    var font: NSFont
    var color: NSColor
    var interval: TimeInterval
    /// Fixed size, or nil to fit the text.
    var size: NSSize?
    var alignment: NSTextAlignment = .left
    var text: (Date) -> String

    /// Draws its text itself. A changing NSTextField invalidates its intrinsic size on every update, which wakes the
    /// SwiftUI host's layout; a view that only redraws doesn't.
    final class Label: NSView {
        var fixed: NSSize?
        var font: NSFont = .systemFont(ofSize: 12) { didSet { needsDisplay = true } }
        var color: NSColor = .labelColor { didSet { needsDisplay = true } }
        var alignment: NSTextAlignment = .left
        private(set) var value = ""
        override var isFlipped: Bool { true }

        private var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: color] }

        func set(_ s: String) {
            guard s != value else { return }
            let widthChanged = fixed == nil && s.count != value.count
            value = s
            needsDisplay = true
            if widthChanged { invalidateIntrinsicContentSize() }
        }

        override var intrinsicContentSize: NSSize {
            if let fixed { return fixed }
            let t = (value as NSString).size(withAttributes: attributes)
            return NSSize(width: ceil(t.width), height: ceil(t.height))
        }

        override func draw(_ dirtyRect: NSRect) {
            let t = (value as NSString).size(withAttributes: attributes)
            var x: CGFloat = 0
            if alignment == .center { x = (bounds.width - t.width) / 2 } else if alignment == .right { x = bounds.width - t.width }
            (value as NSString).draw(at: NSPoint(x: x, y: (bounds.height - t.height) / 2), withAttributes: attributes)
        }
    }

    final class Coordinator {
        var timer: Timer?
        deinit { timer?.invalidate() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Label {
        let l = Label()
        l.fixed = size
        l.font = font
        l.color = color
        l.alignment = alignment
        l.set(text(Date()))
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        let render = text
        let t = Timer(timeInterval: interval, repeats: true) { [weak l] _ in
            l?.set(render(Date()))
        }
        RunLoop.main.add(t, forMode: .common)
        context.coordinator.timer = t
        return l
    }

    func updateNSView(_ l: Label, context: Context) {
        l.font = font
        l.color = color
    }

    static func dismantleNSView(_ l: Label, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.timer = nil
    }
}

struct Spinner: View {
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    var body: some View {
        TickingLabel(font: .systemFont(ofSize: 15, weight: .bold), color: NSColor(Theme.accent), interval: 0.12,
                     size: NSSize(width: 16, height: 20), alignment: .center) { date in
            Self.frames[Int(date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count]
        }
        .frame(width: 16, height: 20)
    }
}

/// "17s": seconds since `start`, ticking once a second without involving SwiftUI.
struct ElapsedLabel: View {
    let start: Date
    var body: some View {
        TickingLabel(font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: NSColor(Theme.text3), interval: 1, size: nil) { date in
            "\(max(0, Int(date.timeIntervalSince(start))))s"
        }
        .fixedSize()
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    func card(_ radius: CGFloat = Theme.radius, fill: Color = Theme.surface, stroke: Color = Theme.border) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke))
    }
}
