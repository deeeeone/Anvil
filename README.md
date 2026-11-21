<p align="center"><img src="design/anvil-icon-1024.png" width="128" alt="Anvil"></p>

# Anvil

A native macOS coding agent in the spirit of Claude Code: open a project folder, describe a change, review every diff, and let the agent read, edit, run and test until it's done.

Anvil reuses the brain of [Peep](../peep) (same provider, same text protocol, same architecture patterns), specialised for coding. It works with any OpenAI-compatible chat model because it doesn't depend on native tool calling. Measured on the default model, a typical small coding task costs a fraction of a cent.

## Features

- **Projects and sessions.** Open any folder. Sessions are saved per project and can be resumed later, model conversation included.
- **Chat with a working agent.** A live status line with a timer, folded and readable tool steps (expand any step to see its output or diff), a Stop button (⌘. or Esc), and follow-ups you type mid-run, which reach the agent with its next step.
- **Coding tools.** `read_file` (line numbers, ranges, images), `edit_file` (exact find/replace with a uniqueness check and recovery hints), `multi_edit` (several files, all or nothing), `write_file`, `delete_file`, `grep`, `glob`, `list_dir`, `shell` (streams live output, with timeouts), background processes (`start_process`, `read_process`, `stop_process`, `list_processes`) for dev servers, `wait_until` (url, port, file, output, process exit, command), `web_search`, `fetch_url`, `todo_write`, skills, `ask_user`, and any MCP server tools.
- **Diff review and permission modes.** Every edit is computed first and shown as a diff. The four modes match Claude Code: *Ask before edits*, *Auto-accept edits*, *Plan only* and *Bypass*. Read-only commands (`ls`, `git status`, `grep`...) always run. Dangerous commands (`rm -r`, `sudo`, `git push`, `git reset --hard`, `curl | sh`...) and writes outside the project ask in Ask and Auto-accept modes. Bypass never asks (edits still get checkpoints). "Always allow `npm test`" covers a command for the rest of the session.
- **Plans and milestones.** Big tasks start with a plan you approve, revise or cancel. Milestones tick off in the chat and in the Todo inspector, along with the agent's todo list.
- **Git.** Branch and status in the title bar, per-file diffs, stage all and commit with a generated message (`/commit` or the Git inspector).
- **Checkpoints.** Each request records the original content of every file it touches. Undo the last task (⌥⌘Z, `/undo`) or rewind to any earlier checkpoint. Shell commands that change files aren't tracked; use git for those.
- **Project memory.** `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md` or `ANVIL.md` in the project root are read into the briefing. `/init` writes one.
- **Slash commands.** `/init`, `/clear`, `/compact [focus]`, `/model [id]`, `/cost`, `/mode`, `/effort`, `/undo`, `/commit`, `/diff`, `/skills`, `/mcp`, `/help`, plus custom commands: markdown files in `.anvil/commands` or `.claude/commands` (project), `~/Library/Application Support/Anvil/commands` or `~/.claude/commands`. `$ARGUMENTS` is replaced with whatever follows the command, and subfolders become `/folder:name`.
- **Skills.** `SKILL.md` folders from the project (`.anvil/skills`, `.claude/skills`), Anvil's own folder and `~/.claude/skills`. Matching skills are mentioned in the briefing and loaded with `use_skill`.
- **Context management.** Old images are dropped and long outputs clipped in batches of 10 messages, so earlier history stays byte-identical and the provider's prompt cache keeps hitting (cached input is about half price). Past a threshold (160k tokens by default) the session is compacted automatically by summarising, and `/compact` does it on demand.
- **Models and providers.** Three providers, chosen from a menu on the composer:
  - **Experiential Labs** (API key): `glm-5.3-flash-uncensored` (default), `glm-5.3-flash` (also the vision model for pasted screenshots), `deepseek-v4.1-flash-uncensored`, `deepseek-v4.1-flash`, with prices.
  - **Luna API** (your keyless OpenAI-compatible endpoint): `gpt-6-luna` and whatever else it lists at `/v1/models`.
  - **Gemini (web)**: `gemini-auto`, `gemini-pro`, `gemini-flash` and `gemini-flash-lite` through gemini.google.com itself, using the same web protocol as [HanaokaYuzu/Gemini-API](https://github.com/HanaokaYuzu/Gemini-API), including pasted images (uploaded the same way the library does). Add one or more Google accounts in Settings by signing in or pasting cookies; Google rotates the cookies and Anvil keeps the rotated values.
  - **ChatGPT (web)**: `chatgpt/*` models (auto, gpt-5.5, gpt-5.5-thinking, o3 and more) through chatgpt.com itself, using the same backend as [zhaees/chatgpt-proxy](https://github.com/zhaees/chatgpt-proxy). Add accounts the same way (sign in or paste cookies). Unofficial, so it can break, and OpenAI may not allow it on your account.
  Accounts are multiple per provider: requests start on the active one and fall through to the others on a dead cookie or rate limit. Each account has its own cookie jar in the Keychain and its own usage count (calls, tokens and errors today, this week and in total), shown in Settings. External proxies still work as a fallback when no account is added.
  **Jailbreak mode** is a toggle in Settings → Agent and in the model menu (flame icon when on). It injects a compact rebel prompt, adapted and tested from [L1B3RT4S](https://github.com/elder-plinius/L1B3RT4S) (AGPL-3.0), ahead of ChatGPT and Gemini requests: no apologies or "I can't", no disclaimers, denser answers. The json reply format and tool names are unchanged. It applies only to the two web providers.
  Settings has one section per provider and **Import keys from Peep** copies both keys. There's a per-session usage and cost meter (Luna, Gemini and ChatGPT are free), and thinking effort defaults to **high**.
- **MCP.** Stdio servers from `~/Library/Application Support/Anvil/mcp.json` and the project's `.mcp.json` (Claude's format) become `server.tool` actions.
- **Background queue.** Press ⌥⏎ in the composer (or type `/queue <task>`) to line up requests. Up to two run at once by default (Settings, Agent: 1 to 4), each in its own git worktree, in the mode you pick in Settings (Auto-accept edits by default). Each finished task's work is committed on its branch, and the Queue section in the sidebar lists the branches to review. Merge one from its session's Git tab.
- **Sub-sessions.** For a feature with independent parts, the agent can split the work: it commits the shared groundwork, then `spawn_session` starts one sub-session per part, each a full agent on its own branch in its own git worktree, running in the background (they share the queue's limit on how many run at once). The main session keeps working, collects reports with `wait_sessions`, answers questions (`message_session`; sub-sessions ask with `message_parent`), and `merge_session` merges each branch. A merge that would conflict is refused with the list of files (checked with `git merge-tree`, without touching the checkout), unless the agent asks to resolve the conflicts itself. Sub-sessions show up in the sidebar as `↳ name`, and you can open, steer or stop any of them. The Git tab's **Merge into main** runs the same conflict check.
- **GitHub.** With the [GitHub CLI](https://cli.github.com) signed in (`gh auth login`), the agent reads issues and pull requests with their comments and inline review comments (`gh_issue`, `gh_pr`), sees CI results with the failing jobs' log tails (`gh_checks`), opens pull requests (`gh_pr_create`, after pushing the branch) and comments (`gh_comment`). Anything that publishes asks first in every mode except Bypass. `/pr` asks the agent to commit the work on a branch and open a PR. Set a label in Settings (for example `anvil`) and open issues carrying it become queue tasks that end in a pull request, checked every five minutes.
- **Live preview and agent browser.** The Preview tab is a real WebKit browser that identifies itself as Safari. When the agent starts a dev server, its address opens there automatically and the page reloads after each edit. The agent drives the same browser through the DOM, so it rarely needs vision:
  - `browser_open`, `browser_read` (visible text, numbered links and fields with their state, viewport, console error count) and `browser_find`;
  - `browser_click`, `browser_type`, `browser_key`, `browser_select`, `browser_hover`, `browser_scroll`, `browser_wait` and `browser_nav`;
  - `browser_console` (console logs, uncaught errors, rejected promises and failed requests, captured from the start of every page) and `browser_viewport` (mobile, tablet, desktop, shown at that size in the Preview tab);
  - `browser_eval` for anything else, and `browser_screenshot` for the vision model when appearance matters.
  The prompt tells the agent to actually use a page when asked to test or audit it, not to trust `fetch_url`. Headless runs get the browser too.
- **iOS Simulator.** The agent builds with `xcodebuild` and then drives the simulator. `sim_list`, `sim_boot`, `sim_run_app`, `sim_launch`, `sim_openurl`, `sim_logs` and `sim_appearance` use `simctl`. `sim_describe` returns the screen's accessibility elements, numbered, without a screenshot. `sim_tap`, `sim_type`, `sim_swipe` and `sim_button` act on the device without moving your mouse, and `sim_screenshot` sends an image to the vision model when the element list isn't enough. The element tools need [AXe](https://github.com/cameroncooke/AXe) (`brew tap cameroncooke/axe && brew install axe`). The Device tab shows the booted simulator live, and clicking it taps the device.
- **Keep awake.** While a request or queue task runs, Anvil holds a power assertion so the Mac doesn't sleep (a cup icon shows in the top bar). Settings can also keep it working with the lid closed: that uses `pmset disablesleep` with your password, and Anvil undoes it when you turn it off or quit.
- **Terminal tabs.** The Terminal tab is a real terminal (SwiftTerm) with tabs: Agent (every command the agent runs, streaming, with colours and autoscroll), one tab per background process, and your own shells (+ opens zsh in the project folder).
- **Rewind.** Hover over one of your messages and click ↶ to go back to just before it: files the agent changed from then on are restored, the conversation is cut there, and the message returns to the composer to edit. If the session was compacted after that point, the files are still restored but the agent starts fresh.
- **Cost and step limits.** Settings sets a per-request cost cap (and the step cap). `/limit $0.02 40` overrides both for a session, and `/limit off` removes the cost cap. Free models never hit it.
- **@-mentions.** Type `@` in the composer to attach a file, a folder, `@git-diff`, `@git-status` or `@last-output`, with autocomplete from the project index.
- **Resumed sessions learn new tools.** A conversation started before Anvil gained a tool (an update, or an MCP server) gets those tools listed with its next request.
- **Learned conventions.** When a follow-up sounds like a lasting preference ("we use tabs, not spaces"), a cheap call rewrites it as one convention line and offers to add it to AGENTS.md, so later sessions follow it.
- **Skill builder.** Final answers of requests that took three or more successful steps show **Save as skill**. A cheap call turns the request and its steps into `.anvil/skills/<name>/SKILL.md`, which is suggested when a later request matches.
- **Notifications.** Only when Anvil isn't in front: approvals come with Allow and Decline buttons, questions take a typed reply, and finished requests and queue tasks send a short note.
- **Design.** Deep blacks, rounded surfaces, one warm coral accent, and a transcript modelled on Claude Code: a dot for each action, a one-line `⎿` result under it, and a cycling ✻ spinner with "esc to interrupt". The layout adapts to the window: wide windows show sidebar, conversation and inspector side by side; medium windows slide the inspector over the chat as a rounded panel; narrow windows hide the sidebar and slide it in on demand. The inspector has Changes (diffs, checkpoints), Files (tree and preview), Plan, Terminal (live output and background processes) and Git.

## What makes it fast and accurate

Each of these is measured by the eval suite (see below):

- **Edit-time syntax checks.** Every edit to Python, JS, JSON, shell, Ruby, Swift, PHP or Go is checked on the spot, and an error lands in the same observation. A broken file stops the batch before the tests run against it.
- **Parallel reads.** Runs of read-only actions in one reply (reads, greps, globs, `repo_map`, `explore`, web) execute concurrently. Re-reading a file that hasn't changed since a recent read returns "unchanged since step N" instead of the contents.
- **Repo map.** The briefing includes every source file with its top-level functions, classes and types, so the model goes straight to the right file. `repo_map` gives a deeper map of a folder.
- **Explore helpers.** `explore {"question"}` starts a read-only helper agent in its own context and returns a short report, which keeps the main context small. Several in one reply run in parallel.
- **Verification gate.** When the agent says it's done after changing files, Anvil runs the project's test command itself (remembered from earlier passing runs, or guessed from the project files). A pass is noted in the answer at no extra model turn. A failure goes back to the agent. With no test command, the agent is asked once to verify.
- **Self-review.** A second, low-effort call reads the request's diff and flags concrete problems (bugs, missed requirements, leftover debug code). Real issues go back to the agent once.
- **Escalation.** When the same action fails twice, or replies keep failing to parse, the next turn goes to the other model family (GLM and DeepSeek), with a nudge to try a different approach.
- **Project memory.** Passing test and build commands, plus lessons from failed requests, are saved per project and shown in later briefings.
- **Streaming.** Reasoning shows live under the spinner. For the Luna API and Gemini (which ignore stop sequences), the stream ends the moment the JSON block closes. A stream that drops mid-reply is retried rather than trusted.
- **Exploration model (optional).** Turns that have only read and searched so far, and explore helpers, can use a faster model (Settings, Agent).
- **Worktree sessions.** "New worktree session" runs the agent on its own branch in its own folder (`../.anvil-worktrees/`), so your checkout stays untouched. Commit there, then **Merge into main** from the Git tab.

- **Adaptive effort.** Each turn's reasoning effort follows what it's likely to do: low for wrap-ups after passing tests and for simple requests, medium for checks, and your setting (high by default) for the first turn of real work, the turn after reading code, and anything after a failure. Wrap-up replies are capped, and redone without the cap if one gets cut off.
- **Request sizing.** Before the first turn, each request is classed as simple (renames, typos: optional quick model, low effort), question, feature, or hard (flaky tests, crashes, performance: escalate after the first failure instead of the second).
- **Prefetch.** A failing command's output is scanned for file and line references (Python tracebacks, Node stacks, compiler errors), and the code around those lines is attached in the same observation. A grep with three hits or fewer comes back with the code around each hit.
- **Type checks after edits (LSP).** After a batch of edits, each changed file goes to the project's language server and only errors the edits *introduced* come back in the observation (the file's errors before Anvil first touched it are the baseline, so a server that can't fully resolve the project doesn't drown the model in noise). Supported: TypeScript and JavaScript with a tsconfig/jsconfig (TypeScript 7's built-in server, else `typescript-language-server`), Python (`pyright`/`basedpyright`), Go (`gopls`), Rust (`rust-analyzer`) and Swift packages (`sourcekit-lsp`). The project's own copy in `node_modules/.bin` or `.venv/bin` is preferred. One server per project and language stays running; a missing server is simply skipped. Both push and pull diagnostics are supported.
- **Line-range edits.** `replace_lines` replaces lines by number in a file the agent read this session and that hasn't changed since. The model doesn't repeat the old text, which roughly halves the output tokens of an edit. Several ranges can go in one call, and the result says how later line numbers shifted.
- **Terse replies.** Routine steps (reads, searches, test runs) skip the reasoning sentence.
- **Project brief.** When a project opens, a cheap call writes a short brief (what the project is, its modules, entry points, how to test it). It's cached and only rewritten when the project's files or symbols change.
- **Cache warming.** When you start typing, Anvil sends the next request's prefix with a 1-token reply so the provider caches it, and the real first turn skips re-reading it. The briefing contains no clock time and no request-specific parts, so the prefix stays identical. This applies to Experiential Labs models.
- **File index.** `glob` and `grep` use an in-memory file list, kept fresh by the file watcher and by the agent's own edits, instead of walking the tree each time.
- **Look-ahead while planning.** While a plan waits for your approval, a read-only helper finds the files and lines milestone 1 will change, and its report arrives with the approval.
- **Fewer approvals.** In Ask mode, one card can approve every edit in a reply ("Allow all 3 in this reply"), and approving a plan approves the edits that carry it out (commands still follow the mode). Bypass never asks at all.

All of these can be switched off in Settings or with headless flags (`--no-verify`, `--no-review`, `--no-escalate`, `--no-stream`, `--no-adaptive`, `--no-prefetch`, `--explore-model ID`, `--quick-model ID`, `--brief`).

## Evals

`evals/tasks/` holds small, realistic coding tasks: fixes, features, refactors across files, implementing from a spec, a dev server, performance, a flaky test, a shell script, and a question that must not change any files. Each task has a `setup.sh`, a `prompt.txt` and a hidden `check.sh` the agent never sees.

```bash
python3 evals/run.py --models glm-5.3-flash-uncensored,deepseek-v4.1-flash-uncensored,gpt-6-luna,gemini-auto --parallel 4
python3 evals/run.py --tasks py-,js-csv -- --no-review          # args after -- go to the agent (ablations)
```

Latest results (16 tasks, Bypass mode, effort high, 21 November 2026):

| Model | Pass | Avg steps | Avg time | Cost (16 tasks) |
|---|---|---|---|---|
| glm-5.3-flash-uncensored | 16/16 | 4.2 | 13.9 s | $0.018 |
| deepseek-v4.1-flash-uncensored | 16/16 | 4.6 | 14.3 s | $0.022 |
| glm-5.3-flash | 16/16 | 3.4 | 48 s | $0.031 |
| deepseek-v4.1-flash | 16/16 | 4.6 | 38 s | $0.067 |
| gpt-6-luna | 13/16 | 3.4 | 105 s | free |
| gemini-auto | not measured | | | free |

- **Speed features:** the first two rows are with adaptive effort, prefetch, line-range edits and terse replies on. A same-day run of glm-5.3-flash-uncensored with adaptive effort and prefetch off averaged 17.6 s, so those two account for about 21%. Against the day before, glm went from 18.8 s to 13.9 s and DeepSeek from 22.9 s to 14.3 s.
- **Older rows:** the glm-5.3-flash, deepseek-v4.1-flash and gpt-6-luna rows are from the run before the speed features.
- **gpt-6-luna:** all three misses were provider errors (duck.ai's 418 challenge and 429 rate limits) before the agent could start.
- **Gemini:** the proxy reported `ready: false` during the runs, so it couldn't be measured.

Each run happens in a fresh git repo under `/tmp/anvil-evals/`, with its own support folder, so evals never touch your sessions or project memory. Results go to `evals/results/*.jsonl`, and a summary table prints at the end.

## Running it

Requires macOS 15, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Anvil.xcodeproj -scheme Anvil -derivedDataPath build build
open build/Build/Products/Debug/Anvil.app
```

On first launch, open Settings (⌘,) and click **Import keys from Peep** (or paste the Experiential Labs key). Keys live in Anvil's own Keychain entries (service `com.diwan.anvil`); macOS may ask once to let Anvil read Peep's. The Luna API needs no key. Cookies for the web providers are kept in the Keychain per account, and nothing is sent anywhere except the site itself.

**Sign in to ChatGPT…** / **Sign in to Gemini…** (in Settings → Provider, or straight from the model menu) opens the provider's sign-in page and adds the account by itself as soon as you're in: no button to press afterwards. Signing in again as the same person refreshes that account instead of adding a duplicate, and an account that stops working shows **Sign in again** on its row. An expired session also heals itself from Safari on the next request, but only when Safari is signed in as the same person. Passkeys and Google's embedded-browser check don't work in a web view (the *site* would have to list Anvil in its Apple association file), so the window has **Use Safari**: sign in there and Anvil picks the session up from Safari's cookies, including a session Safari already has. Reading Safari's cookies needs Full Disk Access; the window shows **Grant Access…** when it's missing and keeps waiting. **Paste cookies…** under each provider adds an account from another browser's Cookie header. No external proxy is needed; the proxy fields under *Advanced* are only a fallback.

If you want to try the association anyway (and for password autofill), `Anvil/AnvilPasskeys.entitlements` has the `webcredentials:` entries; use it as `CODE_SIGN_ENTITLEMENTS` together with a provisioning profile that has Associated Domains. The Safari path works with either entitlements file.

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

`ANVIL_API_KEY` (Experiential Labs) and `ANVIL_GEMINI_KEY` (Gemini proxy) are used in memory only. Neither is passed to the commands the agent runs.

## Architecture

```
Anvil/
  App/      AnvilApp (entry point, menus), AppState (project, sessions, inspector),
            SessionController (runs requests, turns agent events into chat items, persistence),
            Headless (CLI runner and console host), AppInfo (name, paths, formatting)
  Brain/    AgentLoop (observe, think, act), ActionParser (lenient reply parser), PromptBuilder,
            Brain (model routing and usage), OpenAIClient, ChatGPTWebClient, GeminiWebClient,
            Jailbreak, ModelCatalog, ChatMessage, JSON
  Core/     Permissions (pure policy), Diff (Myers line diffs, hunks, unified text), Checkpoints,
            Git (CLI wrapper and porcelain parser), Compactor, Session (models and JSON store),
            ProjectContext (memory files, layout), SlashCommands, SkillLibrary, Settings, Keychain,
            WebAccounts (cookies in the Keychain, per-account usage), SHA3 (ChatGPT proof of work)
  Tools/    Tool (ToolSpec, AgentHost, ToolContext), FileTools, EditEngine, ShellTools,
            ProcessRunner (streaming, timeouts, process-tree kill, background processes),
            WorkTools (web, todos, skills, ask_user), MCPClient
  UI/       ContentView, SidebarView, ConversationView, Composer, InspectorView, DiffView,
            MarkdownText, SettingsView, AccountsView, WebLoginView
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
- **Re-anchoring.** A model that answers "I can't access your files" before doing anything (`gpt-6-luna` did) is reminded that the app runs its actions, up to twice.
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
