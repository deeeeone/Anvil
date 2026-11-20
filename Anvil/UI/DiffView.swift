import SwiftUI

/// Unified diff with line numbers and add/remove colouring.
struct DiffView: View {
    let unified: String
    var compact = false

    var body: some View {
        let lines = DiffEngine.parseUnified(unified)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    row(l)
                }
            }
            .padding(.vertical, 4)
        }
        .font(.system(size: compact ? 11 : 12, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    @ViewBuilder func row(_ l: DiffEngine.Line) -> some View {
        let isHeader = l.oldNo == nil && l.newNo == nil && l.kind == .context
        HStack(spacing: 0) {
            if !isHeader {
                Text(l.oldNo.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.tertiary)
                Text(l.newNo.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.tertiary)
                Text(l.kind == .add ? " + " : l.kind == .remove ? " - " : "   ").foregroundStyle(color(l.kind))
            }
            Text(l.text.isEmpty ? " " : l.text)
                .foregroundStyle(isHeader ? Color.secondary : Color.primary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .padding(.vertical, isHeader ? 3 : 0)
        .background(bg(l.kind, header: isHeader))
    }

    func color(_ k: DiffEngine.Kind) -> Color { k == .add ? .green : k == .remove ? .red : .secondary }
    func bg(_ k: DiffEngine.Kind, header: Bool) -> Color {
        if header { return Color.blue.opacity(0.07) }
        return k == .add ? Color.green.opacity(0.13) : k == .remove ? Color.red.opacity(0.12) : .clear
    }
}
