import SwiftUI

/// Unified diff with line numbers and add/remove colouring. Rows take their natural width (long lines scroll
/// horizontally) and are at least as wide as the view, so the colour bands span it.
struct DiffView: View {
    let unified: String
    var compact = false
    @State private var viewWidth: CGFloat = 300

    var body: some View {
        let lines = DiffEngine.parseUnified(unified)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    row(l)
                }
            }
            .padding(.vertical, 6)
            .frame(minWidth: viewWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .font(.system(size: compact ? 11 : 12, design: .monospaced))
        .card(12, fill: Theme.code)
    }

    /// Height that shows the whole diff up to `max` (nested in other scroll views a diff would otherwise collapse).
    static func height(_ unified: String, compact: Bool = true, max: CGFloat = 300) -> CGFloat {
        let n = CGFloat(DiffEngine.parseUnified(unified).count)
        return Swift.min(max, n * (compact ? 15 : 16.5) + 14)
    }

    @ViewBuilder func row(_ l: DiffEngine.Line) -> some View {
        let isHeader = l.oldNo == nil && l.newNo == nil && l.kind == .context
        HStack(spacing: 0) {
            if !isHeader {
                Text(l.oldNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(Theme.text3.opacity(0.7))
                Text(l.newNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(Theme.text3.opacity(0.7))
                Text(l.kind == .add ? " + " : l.kind == .remove ? " - " : "   ").foregroundStyle(color(l.kind))
            } else {
                Text(" ")
            }
            Text(l.text.isEmpty ? " " : l.text)
                .foregroundStyle(isHeader ? Theme.blue.opacity(0.8) : l.kind == .context ? Theme.text2 : Theme.text)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 12)
        .padding(.vertical, isHeader ? 3 : 0)
        .frame(minWidth: viewWidth, alignment: .leading)
        .background(bg(l.kind, header: isHeader))
    }

    func color(_ k: DiffEngine.Kind) -> Color { k == .add ? Theme.green : k == .remove ? Theme.red : Theme.text3 }
    func bg(_ k: DiffEngine.Kind, header: Bool) -> Color {
        if header { return Theme.blue.opacity(0.06) }
        return k == .add ? Theme.green.opacity(0.09) : k == .remove ? Theme.red.opacity(0.09) : .clear
    }
}
