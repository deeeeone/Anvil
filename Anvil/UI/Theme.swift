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
struct Spinner: View {
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
            let i = Int(ctx.date.timeIntervalSinceReferenceDate / 0.12) % Self.frames.count
            Text(Self.frames[i]).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent).frame(width: 16)
        }
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
