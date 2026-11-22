# Roadmap

## Next
- **Grow the eval suite** to 30 to 50 tasks, including bigger existing repos, and track results over time (a chart of pass rate and cost per model).
- **Per-hunk review.** Accept or reject individual hunks in a diff, and edit the proposed text before applying it.
- **Shell checkpoints.** Snapshot the git working tree (a stash-like commit) before shell commands in auto modes, so undo covers changes those commands make too.
- **Persistent allow rules.** Project-level `.anvil/settings.json` allow and deny lists for commands (like Claude Code's permissions), on top of today's session allow list.
- **Hooks.** Run user commands before and after tool calls (format on save, lint after edit, block patterns).

## Recently shipped
- Worktree cleanup: a sheet (sidebar, or a session's context menu) lists Anvil's worktrees with whether each is merged or has uncommitted files, and removes the ones you pick together with their `anvil/` branches. Merged ones are preselected; anything that would discard work asks first, and the conversation stays as history.
- Sub-session links persist across restarts (they were only in memory), and sub-sessions show nested under their parent in the sidebar with their state. After a restart the main session's agent can wait for, message and merge them again; work that was mid-run when Anvil quit is marked interrupted.
- Token accounting: the context estimate now uses a characters-per-token ratio measured per model from the usage the provider reports, instead of a flat 3.5, and the composer shows a context bar with the share of the last request served from the provider's cache. This is a calibration, not the provider's own tokenizer, which Mac apps can't run for most providers.
- Provider standard: anvil-provider.json for OpenAI-compatible APIs (no code) and process plugins (any language), presets for eight providers, install from a GitHub URL with a confirmation of what it does, website sign-in for plugins, JSON Schema and templates.
- Sub-sessions (spawn, wait, message, merge, with conflict checks), parallel queue, LSP type checks after edits, GitHub through gh (issues, PRs, review comments, CI, labeled issues into the queue), native ChatGPT and Gemini accounts.
- Background queue, live preview with agent browser, rewind, cost limits, @-mentions, learned conventions, skill builder, notifications, app icon.

## Later
- A provider plugin directory: browse repositories tagged `anvil-provider` from inside Anvil.
- Move the four built-in providers onto the plugin spec where they fit (Experiential Labs and Luna are plain OpenAI-compatible APIs).
- HTTP and SSE MCP servers (stdio only today) and MCP resources and prompts.
- Image generation and screenshot tools for front-end work, through the vision model.
- Session search, export to markdown, and pinning.
- Themes, font size and a compact density setting. Syntax highlighting in diffs and file previews.
- Signed and notarised release builds with Sparkle updates.

## Known limitations
- LSP checks cover the files a batch edited; errors a change causes in *other* files show up when the tests run.
- Edits made by shell commands aren't in checkpoints.
- `grep` is a Swift scan that skips common vendor and build folders but doesn't read `.gitignore`.
- The UI check on a 980 pt wide window was done on a capture of a window on another Space; the sidebar looked clipped there but may have been a stale frame.
