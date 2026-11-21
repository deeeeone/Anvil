import SwiftUI
import AppKit

/// Settings → Provider: plugins added from presets, GitHub or a folder, with their key or sign-in.
struct PluginProvidersSection: View {
    @Environment(AppState.self) private var app
    @State private var adding = false

    var body: some View {
        let store = ProviderPlugins.shared
        Section {
            if store.installed.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add any OpenAI-compatible API, or a community plugin").fontWeight(.medium)
                        Text("Z.ai, OpenRouter, Groq, DeepSeek, Ollama and more, or paste a GitHub link.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add provider…") { adding = true }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(store.installed) { p in PluginRow(provider: p) }
                HStack {
                    Button { adding = true } label: { Label("Add provider", systemImage: "plus") }.buttonStyle(.borderless)
                    Spacer()
                    Button("Reload") { store.reload(); Task { await ModelCatalog.shared.refresh() } }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Re-read plugin folders (after editing a linked plugin)")
                }
            }
            ForEach(store.problems.sorted(by: { $0.key < $1.key }), id: \.key) { name, problem in
                if store.provider(name) == nil {
                    Label("\(name): \(problem)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Label("More providers", systemImage: "puzzlepiece.extension")
        } footer: {
            Text("Providers are described by an anvil-provider.json file. Write your own or share one on GitHub: see docs/PROVIDERS.md.")
                .font(.caption)
        }
        .sheet(isPresented: $adding) { AddProviderSheet { app.resetAgents() } }
    }
}

private struct PluginRow: View {
    let provider: InstalledProvider
    @Environment(AppState.self) private var app
    @State private var keyDraft = ""
    @State private var confirmRemove = false
    @State private var update: PendingProvider?
    @State private var note = ""

    var body: some View {
        let store = ProviderPlugins.shared
        let spec = provider.spec
        let ready = store.isReady(provider.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: spec.symbolName).frame(width: 18).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(spec.name).fontWeight(.medium)
                        Text(spec.type == .process ? "plugin" : "API").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Label(ready ? "\(store.models(provider.id).count) models" : "Not set up",
                      systemImage: ready ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(ready ? .green : .secondary)
                Menu {
                    if let home = spec.homepage, let u = URL(string: home) { Button("Open website") { NSWorkspace.shared.open(u) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([provider.folder]) }
                    if provider.fromGitHub { Button("Check for update") { Task { await checkUpdate() } } }
                    Button("Refresh models") { Task { await store.refreshModels(provider.id); await ModelCatalog.shared.refresh() } }
                    if spec.auth.type == .web, ready { Button("Sign out") { store.setSession(provider.id, nil) } }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            }
            switch spec.auth.type {
            case .apiKey:
                HStack {
                    SecureField(store.apiKey(provider.id).isEmpty ? (spec.auth.label ?? "API key") : "Key saved (enter a new one to replace it)", text: $keyDraft)
                    Button("Save") { store.setAPIKey(provider.id, keyDraft); keyDraft = ""; app.resetAgents(); Task { await ModelCatalog.shared.refresh() } }
                        .disabled(keyDraft.isEmpty)
                    if let k = spec.auth.keyURL, let u = URL(string: k) { Link("Get a key", destination: u).font(.caption) }
                }
            case .web:
                if !ready {
                    HStack {
                        Text("Sign in with your \(spec.name) account.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign in…") { PluginLoginWindow.shared.present(provider) { app.resetAgents() } }
                    }
                }
            case .none:
                EmptyView()
            }
            if let problem = store.problems[provider.id] {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
        .confirmationDialog("Remove \(spec.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.remove(provider.id); app.resetAgents() }
        } message: {
            Text(provider.linked ? "Anvil stops using the linked folder; the folder itself stays." : "Its folder, key and session are deleted.")
        }
        .sheet(item: $update) { pending in
            ConfirmProviderView(pending: pending, title: "Update \(spec.name)?") { installed in
                update = nil
                if installed { note = "Updated."; app.resetAgents() }
            }
            .padding(18).frame(width: 520)
        }
    }

    private var subtitle: String {
        var parts = [provider.linked ? "linked: \(provider.source)" : provider.source]
        if provider.spec.type == .openai, let host = URL(string: provider.spec.baseURL ?? "")?.host { parts.append(host) }
        if provider.spec.free == true { parts.append("free") }
        return parts.joined(separator: " · ")
    }

    private func checkUpdate() async {
        note = "Checking…"
        do {
            if let fresh = try await ProviderPlugins.shared.checkForUpdate(provider.id) { note = ""; update = fresh }
            else { note = "Already up to date." }
        } catch {
            note = (error as? ToolFailure)?.message ?? error.localizedDescription
        }
    }
}

/// Add a provider: a preset, a GitHub repository, or a folder you're developing.
struct AddProviderSheet: View {
    var onAdded: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.presets
    @State private var url = ""
    @State private var busy = false
    @State private var error = ""
    @State private var pending: PendingProvider?

    enum Tab: String, CaseIterable { case presets = "Presets", github = "From GitHub", folder = "From a folder" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a provider").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            if let pending {
                ConfirmProviderView(pending: pending, title: pending.replaces ? "Replace \(pending.spec.name)?" : "Install \(pending.spec.name)?") { installed in
                    if installed { onAdded(); dismiss() } else { self.pending = nil }
                }
            } else {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case .presets: presets
                case .github: github
                case .folder: folder
                }
                if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 560, height: 440, alignment: .top)
    }

    private var presets: some View {
        let installed = Set(ProviderPlugins.shared.installed.map(\.id))
        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ProviderPlugins.presets, id: \.id) { spec in
                    Button {
                        do { try ProviderPlugins.shared.add(preset: spec); onAdded(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: spec.symbolName).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(spec.name).fontWeight(.medium)
                                Text(spec.description ?? URL(string: spec.baseURL ?? "")?.host ?? "").font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            if installed.contains(spec.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(installed.contains(spec.id))
                }
            }
        }
    }

    private var github: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the repository of a provider plugin. Anvil downloads it, checks its anvil-provider.json, and shows you what it does before installing anything.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("https://github.com/owner/repo", text: $url).textFieldStyle(.roundedBorder).onSubmit { Task { await fetch() } }
                Button("Fetch") { Task { await fetch() } }.disabled(url.isEmpty || busy).keyboardShortcut(.defaultAction)
                if busy { ProgressView().controlSize(.small) }
            }
            Text("A folder inside a repo works too: …/tree/main/providers/my-provider").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For writing your own plugin: pick the folder with its anvil-provider.json. Anvil uses it in place, so after editing, click Reload in Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                guard panel.runModal() == .OK, let u = panel.url else { return }
                do { pending = try ProviderPlugins.shared.inspect(folder: u); error = "" }
                catch { self.error = (error as? ToolFailure)?.message ?? error.localizedDescription }
            }
        }
    }

    private func fetch() async {
        busy = true
        error = ""
        defer { busy = false }
        do { pending = try await ProviderPlugins.shared.fetch(url) }
        catch { self.error = (error as? ToolFailure)?.message ?? error.localizedDescription }
    }

    private func close() {
        if let pending { ProviderPlugins.shared.discard(pending) }
        dismiss()
    }
}

/// What a plugin will do, and Install / Cancel.
struct ConfirmProviderView: View {
    let pending: PendingProvider
    let title: String
    var onDone: (Bool) -> Void
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: pending.spec.symbolName).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(pending.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let d = pending.spec.description { Text(d).font(.callout) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pending.summary, id: \.self) { line in
                    Label(line, systemImage: pending.spec.type == .process && line.contains("program") ? "exclamationmark.shield" : "info.circle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("Models appear as \(pending.spec.id)/<model> in the model menu.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { ProviderPlugins.shared.discard(pending); onDone(false) }
                Button(pending.replaces ? "Replace" : "Install") {
                    do { try ProviderPlugins.shared.confirm(pending); Task { await ModelCatalog.shared.refresh() }; onDone(true) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
