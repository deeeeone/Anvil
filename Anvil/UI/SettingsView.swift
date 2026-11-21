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
    @State private var expDraft = ""
    @State private var gemDraft = ""
    @State private var note = ""

    var body: some View {
        @Bindable var s = AppSettings.shared
        let catalog = ModelCatalog.shared
        Form {
            Section {
                Picker("Model", selection: $s.model) {
                    ForEach(Provider.allCases) { p in
                        Section(p.label) {
                            ForEach(catalog.choices.filter { $0.provider == p }) { c in Text(c.id).tag(c.id) }
                        }
                    }
                }
                Picker("Vision model (pasted images)", selection: $s.visionModel) {
                    Text("None").tag("")
                    Text("glm-5.3-flash").tag("glm-5.3-flash")
                    ForEach(catalog.geminiModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Thinking effort", selection: $s.effort) { ForEach(AppSettings.efforts, id: \.self) { Text($0).tag($0) } }
                HStack {
                    Button(catalog.loading ? "Refreshing…" : "Refresh model lists") { Task { await catalog.refresh() } }.disabled(catalog.loading)
                    Spacer()
                    if let e = catalog.error { Text(e).font(.caption).foregroundStyle(.orange) }
                }
            } header: { Text("Models") } footer: {
                Text("Effort is high by default: max is about twice as slow per step. Gemini ignores it.").font(.caption)
            }

            Section {
                HStack {
                    SecureField(s.hasKey ? "Key saved (enter a new one to replace it)" : "API key", text: $expDraft)
                    Button("Save") { s.apiKey = expDraft.trimmingCharacters(in: .whitespacesAndNewlines); expDraft = ""; changed() }.disabled(expDraft.isEmpty)
                }
                status(s.ready(.experiential), ok: "Key saved", missing: "No key")
            } header: { Label("Experiential Labs", systemImage: Provider.experiential.symbol) } footer: {
                Text("glm-5.3-flash-uncensored, glm-5.3-flash, deepseek-v4.1-flash-uncensored, deepseek-v4.1-flash.").font(.caption)
            }

            Section {
                TextField("URL", text: $s.lunaURL)
                status(s.ready(.luna), ok: "No key needed, \(catalog.lunaModels.count) models", missing: "Set a URL")
            } header: { Label("Luna API", systemImage: Provider.luna.symbol) }

            Section {
                TextField("URL", text: $s.geminiURL)
                HStack {
                    SecureField(s.geminiKey.isEmpty ? "Proxy key" : "Key saved (enter a new one to replace it)", text: $gemDraft)
                    Button("Save") { s.geminiKey = gemDraft.trimmingCharacters(in: .whitespacesAndNewlines); gemDraft = ""; changed() }.disabled(gemDraft.isEmpty)
                }
                status(s.ready(.gemini), ok: "Key saved", missing: "No key")
            } header: { Label("Gemini (web proxy)", systemImage: Provider.gemini.symbol) }

            Section {
                HStack {
                    Button("Import keys from Peep") {
                        let got = s.importKeyFromPeep()
                        note = got.isEmpty ? "Couldn't read Peep's keys (not found, or access was denied)." : "Imported: " + got.joined(separator: ", ") + "."
                        changed()
                    }
                    Spacer()
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } footer: { Text("Copies the Experiential Labs and Gemini proxy keys into Anvil's own Keychain entries. macOS may ask once.").font(.caption) }
        }
        .formStyle(.grouped)
        .onChange(of: s.model) { _, _ in app.resetAgents() }
        .onChange(of: s.effort) { _, _ in app.resetAgents() }
        .task { await catalog.refresh() }
    }

    func status(_ ok: Bool, ok okText: String, missing: String) -> some View {
        Label(ok ? okText : missing, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(ok ? .green : .orange)
    }

    func changed() {
        app.resetAgents()
        Task { await ModelCatalog.shared.refresh() }
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
            Section {
                Toggle("Verify before finishing (run the project's tests after edits)", isOn: $s.autoVerify)
                Toggle("Review the diff before finishing (one extra model call)", isOn: $s.selfReview)
                Toggle("Stream replies", isOn: $s.streaming)
                Toggle("Adaptive effort (lighter thinking on routine turns; your effort setting is the ceiling)", isOn: $s.adaptiveEffort)
                Toggle("Attach the code an error points to", isOn: $s.prefetch)
                Toggle("Look ahead while a plan waits for approval", isOn: $s.prepareWhilePlanning)
                Toggle("Warm the prompt cache while you type", isOn: $s.warmCache)
                Toggle("Keep a project brief (one cheap call when the project changes)", isOn: $s.projectBrief)
                Picker("Model for simple requests", selection: $s.quickModel) {
                    Text("Same as the session").tag("")
                    ForEach(ModelCatalog.shared.choices) { Text($0.id).tag($0.id) }
                }
                Picker("After repeated failures, switch to", selection: $s.escalationModel) {
                    Text("Off").tag("")
                    Text("Auto (the other model family)").tag("auto")
                    ForEach(ModelCatalog.shared.choices) { Text($0.id).tag($0.id) }
                }
                Picker("Exploration model", selection: $s.exploreModel) {
                    Text("Same as the session").tag("")
                    ForEach(ModelCatalog.shared.choices) { Text($0.id).tag($0.id) }
                }
            } header: { Text("Accuracy and speed") } footer: {
                Text("Every edit is syntax-checked. The exploration model handles explore helpers and turns that only read and search.").font(.caption)
            }
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
                        Text(s.source).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
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
                Text("Anvil reads its own \(MCPServerConfig.fileURL.path), the project's .mcp.json, and your Peep, Claude Desktop and Claude Code configs (the first definition of a name wins). The agent can also add servers with add_mcp_server.").font(.caption)
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

    var body: some View {
        let catalog = ModelCatalog.shared
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Model").font(.system(size: 16, weight: .semibold))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh model lists") { Task { await catalog.refresh() } }
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Provider.allCases) { p in
                        let list = catalog.choices.filter { $0.provider == p }
                        let ready = AppSettings.shared.ready(p)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: p.symbol)
                                Text(p.label.uppercased())
                                if !ready { Text("· not set up").foregroundStyle(Theme.amber) }
                            }
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3).padding(.leading, 10)
                            ForEach(list) { c in
                                Button {
                                    controller.model = c.id
                                    dismiss()
                                } label: {
                                    HoverRow(selected: c.id == controller.model) {
                                        HStack(spacing: 10) {
                                            Image(systemName: c.id == controller.model ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(c.id == controller.model ? Theme.accent : Theme.text3)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(c.id).font(.system(size: 13, weight: .medium)).foregroundStyle(ready ? Theme.text : Theme.text3)
                                                if !c.detail.isEmpty { Text(c.detail).font(.system(size: 11)).foregroundStyle(Theme.text3) }
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(!ready)
                            }
                        }
                    }
                }
            }
            if let e = catalog.error { Text(e).font(.caption).foregroundStyle(Theme.amber) }
            HStack {
                Text("Effort: \(AppSettings.shared.effort). Set up providers in Settings (⌘,).").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: 560)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task { await catalog.refresh() }
    }
}
