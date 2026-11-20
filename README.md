# Anvil

A native macOS coding agent in the spirit of Claude Code: open a project folder, describe a change, review every diff, and let the agent read, edit, run and test until it's done.

Anvil reuses the brain of [Peep](../peep) (same provider, same text protocol, same architecture patterns), specialised for coding. It works with any OpenAI-compatible chat model because it doesn't depend on native tool calling. Measured on the default model, a typical small coding task costs a fraction of a cent.

## Features

- **Projects and sessions.** Open any folder. Sessions are saved per project and can be resumed later, model conversation included.
- **Chat with a working agent.** A live status line with a timer, folded and readable tool steps (expand any step to see its output or diff), a Stop button (⌘. or Esc), and follow-ups you type mid-run, which reach the agent with its next step.
- **Coding tools.** `read_file` (line numbers, ranges, images), `edit_file` (exact find/replace with a uniqueness check and recovery hints), `multi_edit` (several files, all or nothing), `write_file`, `delete_file`, `grep`, `glob`, `list_dir`, `shell` (streams live output, with timeouts), background processes (`start_process`, `read_process`, `stop_process`, `list_processes`) for dev servers, `wait_until` (url, port, file, output, process exit, command), `web_search`, `fetch_url`, `todo_write`, skills, `ask_user`, and any MCP server tools.
- **Diff review and permission modes.** Every edit is computed first and shown as a diff. The four modes match Claude Code: *Ask before edits*, *Auto-accept edits*, *Plan only* and *Bypass*. Read-only commands (`ls`, `git status`, `grep`...) always run. Dangerous commands (`rm -r`, `sudo`, `git push`, `git reset --hard`, `curl | sh`...) and writes outside the project always ask, in every mode. "Always allow `npm test`" covers a command for the rest of the session.
- **Plans and milestones.** Big tasks start with a plan you approve, revise or cancel. Milestones tick off in the chat and in the Todo inspector, along with the agent's todo list.
- **Git.** Branch and status in the title bar, per-file diffs, stage all and commit with a generated message (`/commit` or the Git inspector).
- **Checkpoints.** Each request records the original content of every file it touches. Undo the last task (⌥⌘Z, `/undo`) or rewind to any earlier checkpoint. Shell commands that change files aren't tracked; use git for those.
- **Project memory.** `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md` or `ANVIL.md` in the project root are read into the briefing. `/init` writes one.
- **Slash commands.** `/init`, `/clear`, `/compact [focus]`, `/model [id]`, `/cost`, `/mode`, `/effort`, `/undo`, `/commit`, `/diff`, `/skills`, `/mcp`, `/help`, plus custom commands: markdown files in `.anvil/commands` or `.claude/commands` (project), `~/Library/Application Support/Anvil/commands` or `~/.claude/commands`. `$ARGUMENTS` is replaced with whatever follows the command, and subfolders become `/folder:name`.
- **Skills.** `SKILL.md` folders from the project (`.anvil/skills`, `.claude/skills`), Anvil's own folder and `~/.claude/skills`. Matching skills are mentioned in the briefing and loaded with `use_skill`.
- **Context management.** Old images are dropped and long outputs clipped in batches of 10 messages, so earlier history stays byte-identical and the provider's prompt cache keeps hitting (cached input is about half price). Past a threshold (160k tokens by default) the session is compacted automatically by summarising, and `/compact` does it on demand.
- **Models and cost.** The model picker reads the provider's `/v1/models` with prices and context sizes. The usage and cost meter shows per-session totals, and the context size is shown under the composer. Thinking effort defaults to **high** (the provider default, max, is about twice as slow per step). An optional vision model handles pasted screenshots (⌘V, drag and drop, or the paperclip).
- **MCP.** Stdio servers from `~/Library/Application Support/Anvil/mcp.json` and the project's `.mcp.json` (Claude's format) become `server.tool` actions.
- **3-pane layout.** Sessions and a file tree in the sidebar, the conversation, and an inspector with Changes (diffs, file preview, checkpoints), Todo, Terminal (live shell output and background processes) and Git.

## Running it

Requires macOS 15, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build build
open build/Build/Products/Debug/Anvil.app
```

On first launch, open Settings (⌘,) and either paste an API key or click **Import key from Peep**. The key lives in Anvil's own Keychain entry (service `com.diwan.anvil`); macOS may ask once to let Anvil read Peep's entry. The default provider is the Experiential Labs gateway (`https://api.experientiallabs.ai`), with `glm-5.3-flash-uncensored` as the model and `glm-5.3-flash` for images.

Tests:

```bash
xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build test
```

### Headless mode

The same agent runs without UI, which is handy for scripted evals. Sessions are saved, so they show up in the app afterwards.

```bash
ANVIL_API_KEY=... build/Build/Products/Debug/Anvil.app/Contents/MacOS/Anvil --headless \
  --project ~/code/myapp --prompt "Fix the failing test" --mode edits --approve
```

- `--mode`: `ask`, `edits`, `plan` or `bypass`.
- `--approve`: answers permission prompts with yes, except dangerous commands.
- `--resume SESSION-ID`: continues a saved session.
- `--model ID`, `--max-steps N`: override the model and the step limit.
- `--parse FILE`: runs the reply parser on a saved model reply, for debugging protocol drift.

`ANVIL_API_KEY` is used in memory only and is removed from the environment of every command the agent runs.

## Architecture

```
Anvil/
  App/      AnvilApp (entry point, menus), AppState (project, sessions, inspector),
            SessionController (runs requests, turns agent events into chat items, persistence),
            Headless (CLI runner and console host), AppInfo (name, paths, formatting)
  Brain/    AgentLoop (observe, think, act), ActionParser (lenient reply parser), PromptBuilder,
            Brain (model routing and usage), OpenAIClient, ModelCatalog, ChatMessage, JSON
  Core/     Permissions (pure policy), Diff (Myers line diffs, hunks, unified text), Checkpoints,
            Git (CLI wrapper and porcelain parser), Compactor, Session (models and JSON store),
            ProjectContext (memory files, layout), SlashCommands, SkillLibrary, Settings, Keychain
  Tools/    Tool (ToolSpec, AgentHost, ToolContext), FileTools, EditEngine, ShellTools,
            ProcessRunner (streaming, timeouts, process-tree kill, background processes),
            WorkTools (web, todos, skills, ask_user), MCPClient
  UI/       ContentView, SidebarView, ConversationView, Composer, InspectorView, DiffView,
            MarkdownText, SettingsView
AnvilTests/ parser, edit engine, diffs, permissions, git, compaction, checkpoints, commands,
            sessions, pricing, and scripted agent-loop runs against a fake model
```

### The protocol

Peep's text protocol (see Peep's `docs/PROTOCOL.md`), adapted for coding:

1. The first user turn is the briefing: role, reply format, coding rules and the tool catalog (fixed, so it caches across sessions), then project context (path, git state, layout, `AGENTS.md`, matching skills), then the request.
2. Every reply is one or two sentences of reasoning followed by one fenced JSON block: `{"say", "actions": [{"tool", "args"}], "done", "plan", "milestone"}`.
3. Actions run in order and the batch stops at the first failure. Edit tools *prepare* their changes; the app computes the diffs, applies the permission policy, records checkpoints and only then writes.
4. Results come back in one `<observation>` user turn, along with any messages the owner typed meanwhile, mode changes and budget notes.

Hardening that came out of live runs:
- **First block wins.** Stop sequences end a reply when the model starts writing its own observation, and only the first JSON block runs. The model is told if extra blocks were ignored.
- **String-aware repairs.** The parser fixes trailing commas, comments, Python literals, raw newlines, missing braces and cut-off replies without ever touching the contents of JSON strings (file contents).
- **Useful parse errors.** When a reply still can't be parsed, the model is shown where its JSON broke.
- **No blind overwrites.** `write_file` refuses to overwrite a file the agent hasn't read in this session.
- **Servers go to the background.** Server commands sent to `shell` are redirected to `start_process`.
- **Tests stay honest.** The prompt forbids weakening tests to get them passing.

## Sandbox evaluation (glm-5.3-flash-uncensored, effort high)

| Task | Result | Steps | Time | Cost |
|---|---|---|---|---|
| Scaffold a Python CLI todo app with pytest tests | 8 tests pass | 4 | 40 s | $0.0020 |
| Add due dates and an `overdue` command, with tests (resumed session) | 15 tests pass | 8 | 57 s | $0.0076 |
| Find and fix the failing JS test, code only (Ask mode) | one-line root-cause fix, 7/7 pass | 4 | 30 s | $0.0008 |
| Refactor storage into a `TodoStore` class with unit tests (Plan mode) | 26 tests pass, CLI output unchanged | 13 | 66 s | $0.0069 |
| In the GUI: fix `median`/`mean` and add unittest tests, approving each diff | 8 tests pass | 4 | about 90 s including approvals | $0.0006 |

The runs found and fixed:
- an AppKit layout loop (the SwiftUI inspector inside a split view crashed the app);
- replies that ran ahead with an imagined observation;
- JSON repairs that rewrote `True` inside file contents;
- a missing brace between actions;
- an over-strict `rm -f` rule;
- an over-broad "always allow python3".

## Renaming

The product name lives in `project.yml` (target, bundle id) and `Anvil/App/AppInfo.swift` (display name, bundle id, support folder).
