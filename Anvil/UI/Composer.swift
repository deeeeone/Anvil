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
    @State private var text = ""
    @State private var images: [AttachedImage] = []
    @State private var history: [String] = []
    @State private var selection = 0
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    var suggestions: [SlashCommand] { SlashCommands.suggestions(text, project: controller.root).prefix(8).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, c in
                        Button { complete(c) } label: {
                            HStack {
                                Text("/\(c.name)").font(.callout.monospaced()).fontWeight(.medium)
                                Text(c.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if c.source != "built-in" { Text(c.source).font(.caption2).foregroundStyle(.tertiary) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(i == selection ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
            if !images.isEmpty {
                HStack {
                    ForEach(images) { img in
                        ZStack(alignment: .topTrailing) {
                            if let t = img.thumb { Image(nsImage: t).resizable().scaledToFill().frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 6)) }
                            Button { images.removeAll { $0.id == img.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).offset(x: 5, y: -5)
                        }
                    }
                    if AppSettings.shared.visionModel.isEmpty {
                        Text("Set a vision model in Settings to send images.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Attach an image (or paste one with ⌘V)")
                    .padding(.bottom, 3)
                TextField(controller.running ? "Add a note for the agent (delivered with its next step)" : "Ask for a change, a fix or an explanation. / for commands",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
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
                    .padding(.vertical, 3)
                if controller.running && text.isEmpty {
                    Button { controller.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.red).help("Stop (⌘. or Esc)")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(text.isEmpty && images.isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(text.isEmpty && images.isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1))
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in drop(providers) }
            HStack(spacing: 10) {
                Label(controller.mode.label, systemImage: controller.mode.symbol).foregroundStyle(controller.mode == .bypass ? .red : .secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("context ~\(Fmt.tokens(max(controller.session.usage.lastPrompt, Compactor.estimateTokens(controller.session.messages))))")
                if controller.session.usage.calls > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(controller.session.usage.line)
                }
                Spacer()
                Text("⏎ send · ⇧⏎ newline · ⇧⌘M mode").foregroundStyle(.tertiary)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
        .onAppear {
            focused = true
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.charactersIgnoringModifiers?.lowercased() == "v", e.modifierFlags.contains(.command) else { return e }
                return pasteImage() ? nil : e
            }
        }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m) } }
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
