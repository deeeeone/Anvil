import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AttachedImage: Identifiable {
    let id = UUID()
    var data: Data
    var mime: String
    var thumb: NSImage?
}

struct Composer: View {
    @Environment(AppState.self) private var app
    let controller: SessionController
    var prominent = false
    @State private var text = ""
    @State private var images: [AttachedImage] = []
    @State private var history: [String] = []
    @State private var selection = 0
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    var suggestions: [SlashCommand] { SlashCommands.suggestions(text, project: controller.root).prefix(8).map { $0 } }
    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty { suggestionList }
            VStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty { attachments }
                TextField(controller.running ? "Add a note for the agent, it arrives with the next step" : "Ask for a change, a fix or an explanation",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .lineLimit(prominent ? 3...12 : 1...12)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { text += "\n"; return .handled }
                        if !suggestions.isEmpty && !text.contains(" ") {
                            let c = suggestions[min(selection, suggestions.count - 1)]
                            if "/\(c.name)" != text { complete(c); return .handled }
                        }
                        send(); return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !suggestions.isEmpty else { return .ignored }
                        complete(suggestions[min(selection, suggestions.count - 1)]); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if !suggestions.isEmpty { selection = max(0, selection - 1); return .handled }
                        guard text.isEmpty, let last = history.last else { return .ignored }
                        text = last; return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !suggestions.isEmpty else { return .ignored }
                        selection = min(suggestions.count - 1, selection + 1); return .handled
                    }
                    .onKeyPress(.escape) {
                        if controller.running && text.isEmpty { controller.stop(); return .handled }
                        guard !text.isEmpty else { return .ignored }
                        text = ""; return .handled
                    }
                    .onChange(of: text) { _, _ in selection = 0 }
                HStack(spacing: 6) {
                    IconButton(symbol: "paperclip", help: "Attach an image (or paste one with ⌘V)", size: 28) { attach() }
                    ModePill(controller: controller)
                    ModelPill(controller: controller)
                    Spacer(minLength: 4)
                    Text("~\(Fmt.tokens(max(controller.session.usage.lastPrompt, Compactor.estimateTokens(controller.session.messages)))) ctx")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3).lineLimit(1)
                        .layoutPriority(-1)
                        .help("Approximate context size. /compact frees space.")
                    sendButton
                }
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(focused ? Theme.accent.opacity(0.45) : Theme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in drop(providers) }
            .onTapGesture { focused = true }
        }
        .onAppear {
            focused = true
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.charactersIgnoringModifiers?.lowercased() == "v", e.modifierFlags.contains(.command) else { return e }
                return pasteImage() ? nil : e
            }
        }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m) } }
    }

    @ViewBuilder var sendButton: some View {
        if controller.running && !canSend {
            Button { controller.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 30, height: 30).background(Theme.surface2, in: Circle())
                    .overlay(Circle().stroke(Theme.borderStrong))
            }
            .buttonStyle(.plain).help("Stop (esc or ⌘.)")
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(canSend ? .white : Theme.text3)
                    .frame(width: 30, height: 30).background(canSend ? Theme.accent : Theme.surface2, in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSend).help("Send (⏎). New line: ⇧⏎")
        }
    }

    var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, c in
                Button { complete(c) } label: {
                    HStack(spacing: 10) {
                        Text("/\(c.name)").font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(i == selection ? Theme.accent : Theme.text)
                        Text(c.summary).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                        Spacer(minLength: 4)
                        if c.source != "built-in" { Text(c.source).font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i == selection ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .card(14, fill: Theme.surface, stroke: Theme.borderStrong)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }

    var attachments: some View {
        HStack(spacing: 8) {
            ForEach(images) { img in
                ZStack(alignment: .topTrailing) {
                    if let t = img.thumb {
                        Image(nsImage: t).resizable().scaledToFill().frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Button { images.removeAll { $0.id == img.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(.black.opacity(0.75), in: Circle())
                    }
                    .buttonStyle(.plain).offset(x: 5, y: -5)
                }
            }
            if AppSettings.shared.visionModel.isEmpty {
                Text("Set a vision model in Settings to send images.").font(.caption).foregroundStyle(Theme.amber)
            }
        }
    }

    func complete(_ c: SlashCommand) {
        text = "/\(c.name)" + (["model", "mode", "effort", "compact"].contains(c.name) || c.body != nil ? " " : "")
        if c.body == nil && !["model", "mode", "effort", "compact"].contains(c.name) { send() }
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !images.isEmpty else { return }
        if !t.isEmpty { history.append(t) }
        controller.send(t, images: images.map { ($0.data, $0.mime) })
        text = ""
        images = []
    }

    func add(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        // Downscale big screenshots: the vision model doesn't need retina pixels.
        let maxSide: CGFloat = 1600
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxSide / max(w, h))
        var data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        if scale < 1 {
            let size = NSSize(width: w * scale, height: h * scale)
            let small = NSImage(size: size)
            small.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: size))
            small.unlockFocus()
            if let t = small.tiffRepresentation, let r = NSBitmapImageRep(data: t) { data = r.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }
        }
        if let data { images.append(AttachedImage(data: data, mime: "image/jpeg", thumb: img)) }
    }

    func pasteImage() -> Bool {
        let pb = NSPasteboard.general
        if pb.string(forType: .string)?.isEmpty == false { return false }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var handled = false
            for u in urls where FileTools.imageExts.contains(u.pathExtension.lowercased()) {
                if let img = NSImage(contentsOf: u) { add(img); handled = true }
            }
            if !handled { text += urls.map(\.path).joined(separator: " ") }
            return true
        }
        if let img = NSImage(pasteboard: pb) { add(img); return true }
        return false
    }

    func attach() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { if let img = NSImage(contentsOf: u) { add(img) } } }
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if FileTools.imageExts.contains(url.pathExtension.lowercased()), let img = NSImage(contentsOf: url) { add(img) }
                    else { text += (text.isEmpty ? "" : " ") + Paths.display(url, root: controller.root) }
                }
            }
        }
        return true
    }
}

struct ModePill: View {
    let controller: SessionController
    var color: Color {
        switch controller.mode { case .bypass: return Theme.red; case .plan: return Theme.blue; case .acceptEdits: return Theme.accent; case .ask: return Theme.text2 }
    }
    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { m in
                Button { controller.mode = m } label: { Label(m.label, systemImage: m.symbol) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.mode.symbol).font(.system(size: 11, weight: .semibold))
                Text(controller.mode.short).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(controller.mode == .ask ? 0 : 0.12), in: Capsule())
            .overlay(Capsule().stroke(controller.mode == .ask ? Theme.border : .clear))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("\(controller.mode.label). ⇧⌘M cycles. Dangerous commands always ask.")
    }
}

struct ModelPill: View {
    @Environment(AppState.self) private var app
    let controller: SessionController
    var body: some View {
        Button { app.showModelPicker = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 11, weight: .semibold))
                Text(controller.model).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.border))
            .contentShape(Capsule())
            .frame(maxWidth: 200, alignment: .leading)
        }
        .buttonStyle(.plain)
        .layoutPriority(-0.5)
        .help("Model (effort: \(AppSettings.shared.effort))")
    }
}
