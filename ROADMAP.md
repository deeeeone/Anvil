# Roadmap

## Next
- **Grow the eval suite** to 30 to 50 tasks, including bigger existing repos, and track results over time (a chart of pass rate and cost per model).
- **Per-hunk review.** Accept or reject individual hunks in a diff, and edit the proposed text before applying it.
- **Shell checkpoints.** Snapshot the git working tree (a stash-like commit) before shell commands in auto modes, so undo covers changes those commands make too.
- **Persistent allow rules.** Project-level `.anvil/settings.json` allow and deny lists for commands (like Claude Code's permissions), on top of today's session allow list.
- **Hooks.** Run user commands before and after tool calls (format on save, lint after edit, block patterns).

## Recently shipped
- Background queue, live preview with agent browser, rewind, cost limits, @-mentions, learned conventions, skill builder, notifications, app icon.

## Later
- Worktree cleanup: remove merged worktrees and branches from the app.
- A `gh` integration: PR creation, review comments into the chat, CI status.
- An LSP bridge for type-level diagnostics after edits (TypeScript, Swift, Python), on top of today's syntax checks.
- HTTP and SSE MCP servers (stdio only today) and MCP resources and prompts.
- Image generation and screenshot tools for front-end work, through the vision model.
- Better token accounting: a provider tokenizer instead of the 3.5 characters per token estimate, and a context bar showing cache hits.
- Session search, export to markdown, and pinning.
- Themes, font size and a compact density setting. Syntax highlighting in diffs and file previews.
- Signed and notarised release builds with Sparkle updates.

## Known limitations
- Edits made by shell commands aren't in checkpoints.
- `grep` is a Swift scan that skips common vendor and build folders but doesn't read `.gitignore`.
- The UI check on a 980 pt wide window was done on a capture of a window on another Space; the sidebar looked clipped there but may have been a stale frame.
