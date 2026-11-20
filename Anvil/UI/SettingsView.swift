import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProviderSettings().tabItem { Label("Provider", systemImage: "cpu") }
            AgentSettings().tabItem { Label("Agent", systemImage: "gearshape.2") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 520)
    }
}

struct ProviderSettings: View {
    @Environment(AppState.self) private var app
    @State private var keyDraft = ""
    @State private var note = ""
    private var s: AppSettings { AppSettings.shared }

    var body: some View {
        @Bindable var s = AppSettings.shared
        let catalog = ModelCatalog.shared
        Form {
            Section("OpenAI-compatible provider") {
                TextField("Base URL", text: $s.baseURL)
                HStack {
                    SecureField(s.hasKey ? "Key saved in the Keychain (enter a new one to replace it)" : "API key", text: $keyDraft)
                    Button("Save") { s.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines); keyDraft = ""; note = "Saved."; app.resetAgents(); Task { await catalog.refresh() } }
                        .disabled(keyDraft.isEmpty)
                }
                HStack {
                    Button("Import key from Peep") {
                        note = s.importKeyFromPeep() ? "Imported Peep's key into Anvil's Keychain entry." : "Couldn't read Peep's key (not found, or access was denied)."
                        app.resetAgents()
                        Task { await catalog.refresh() }
                    }
                    .disabled(!s.peepKeyAvailable)
                    if s.hasKey { Button("Remove key", role: .destructive) { s.apiKey = ""; app.resetAgents() } }
                    Spacer()
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ModelPickerRow(title: "Model", selection: $s.model, models: catalog.chatModels)
                ModelPickerRow(title: "Vision model (pasted images)", selection: $s.visionModel, models: catalog.chatModels, allowNone: true)
                Picker("Thinking effort", selection: $s.effort) { ForEach(AppSettings.efforts, id: \.self) { Text($0).tag($0) } }
                Picker("Vision effort", selection: $s.visionEffort) { ForEach(AppSettings.efforts, id: \.self) { Text($0).tag($0) } }
                HStack {
                    Button(catalog.loading ? "Refreshing…" : "Refresh models") { Task { await catalog.refresh() } }.disabled(catalog.loading)
                    if let e = catalog.error { Text(e).font(.caption).foregroundStyle(.red) }
                    else { Text("\(catalog.models.count) models").font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("Models") } footer: {
                Text("High effort is the default: the provider's max is about twice as slow per step for little gain on coding tasks.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.model) { _, _ in app.resetAgents() }
        .onChange(of: s.effort) { _, _ in app.resetAgents() }
        .task { if catalog.models.isEmpty && s.hasKey { await catalog.refresh() } }
    }
}

struct ModelPickerRow: View {
    let title: String
    @Binding var selection: String
    let models: [ModelInfo]
    var allowNone = false
    var body: some View {
        Picker(title, selection: $selection) {
            if allowNone { Text("None").tag("") }
            if !models.contains(where: { $0.id == selection }) && !selection.isEmpty { Text(selection).tag(selection) }
            ForEach(models) { m in Text("\(m.id)  ·  \(m.priceLabel)").tag(m.id) }
        }
    }
}

struct AgentSettings: View {
    var body: some View {
        @Bindable var s = AppSettings.shared
        Form {
            Picker("Default permission mode", selection: $s.defaultMode) {
                ForEach(PermissionMode.allCases) { Text($0.label).tag($0) }
            }
            Stepper("Max steps per request: \(s.maxSteps)", value: $s.maxSteps, in: 10...300, step: 10)
            Stepper("Auto-compact above ~\(Fmt.tokens(s.autoCompactTokens)) tokens", value: $s.autoCompactTokens, in: 40_000...900_000, step: 20_000)
            Stepper("Shell timeout: \(Int(s.shellTimeout))s", value: $s.shellTimeout, in: 30...1800, step: 30)
            Section("Permission modes") {
                Text("Ask before edits: shows each diff and command for approval. Auto-accept edits: file changes apply without asking, commands still ask. Plan only: read-only until you approve a plan. Bypass: everything runs. Dangerous commands (rm -rf, sudo, git push, git reset --hard...) always ask, in every mode.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let mcp = MCPManager.shared
        Form {
            Section {
                if mcp.servers.isEmpty { Text("No servers configured.").foregroundStyle(.secondary) }
                ForEach(mcp.servers) { s in
                    HStack {
                        Text(s.name).fontWeight(.medium)
                        Text(s.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(s.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Edit mcp.json") { mcp.openConfig() }
                    Button("Reconnect") { mcp.start(project: app.project); app.resetAgents() }
                }
            } header: { Text("MCP servers") } footer: {
                Text("Global servers live in \(MCPServerConfig.fileURL.path); a project's .mcp.json is merged in.").font(.caption)
            }
            Section("Skills and commands") {
                Text("Skills: SKILL.md folders in the project's .anvil/skills or .claude/skills, \(SkillLibrary.anvilDir.path), and ~/.claude/skills.").font(.callout)
                Text("Custom slash commands: markdown files in .anvil/commands or .claude/commands (project), \(Paths.support.appendingPathComponent("commands").path), or ~/.claude/commands. $ARGUMENTS is replaced with the text after the command.").font(.callout)
                Button("Open Anvil's folder") { NSWorkspace.shared.open(Paths.support) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: SessionController
    @State private var query = ""

    var body: some View {
        let catalog = ModelCatalog.shared
        let list = catalog.chatModels.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Model for this session").font(.headline)
                Spacer()
                Button(catalog.loading ? "Refreshing…" : "Refresh") { Task { await catalog.refresh() } }
            }
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder)
            List(list) { m in
                Button {
                    controller.model = m.id
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: m.id == controller.model ? "checkmark.circle.fill" : "circle").foregroundStyle(m.id == controller.model ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(m.id).fontWeight(.medium)
                            Text([m.priceLabel, m.contextLabel, m.reasoning ? "reasoning" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let e = catalog.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Effort: \(AppSettings.shared.effort) (change in Settings or with /effort)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
        .task { if catalog.models.isEmpty { await catalog.refresh() } }
    }
}
