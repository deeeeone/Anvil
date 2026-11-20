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
            .padding(.vertical, 4)
            .frame(minWidth: viewWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .font(.system(size: compact ? 11 : 12, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    @ViewBuilder func row(_ l: DiffEngine.Line) -> some View {
        let isHeader = l.oldNo == nil && l.newNo == nil && l.kind == .context
        HStack(spacing: 0) {
            if !isHeader {
                Text(l.oldNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
                Text(l.newNo.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(.tertiary)
                Text(l.kind == .add ? " + " : l.kind == .remove ? " - " : "   ").foregroundStyle(color(l.kind))
            } else {
                Text(" ")
            }
            Text(l.text.isEmpty ? " " : l.text)
                .foregroundStyle(isHeader ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 12)
        .padding(.vertical, isHeader ? 3 : 0)
        .frame(minWidth: viewWidth, alignment: .leading)
        .background(bg(l.kind, header: isHeader))
    }

    func color(_ k: DiffEngine.Kind) -> Color { k == .add ? .green : k == .remove ? .red : .secondary }
    func bg(_ k: DiffEngine.Kind, header: Bool) -> Color {
        if header { return Color.blue.opacity(0.07) }
        return k == .add ? Color.green.opacity(0.13) : k == .remove ? Color.red.opacity(0.12) : .clear
    }
}
