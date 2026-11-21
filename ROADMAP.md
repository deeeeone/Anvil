# Roadmap

## Next
- **Grow the eval suite** to 30 to 50 tasks, including bigger existing repos, and track results over time (a chart of pass rate and cost per model).
- **Per-hunk review.** Accept or reject individual hunks in a diff, and edit the proposed text before applying it.
- **Shell checkpoints.** Snapshot the git working tree (a stash-like commit) before shell commands in auto modes, so undo covers changes those commands make too.
- **Persistent allow rules.** Project-level `.anvil/settings.json` allow and deny lists for commands (like Claude Code's permissions), on top of today's session allow list.
- **Hooks.** Run user commands before and after tool calls (format on save, lint after edit, block patterns).

## Recently shipped
- Sub-sessions (spawn, wait, message, merge, with conflict checks), parallel queue, LSP type checks after edits, GitHub through gh (issues, PRs, review comments, CI, labeled issues into the queue), native ChatGPT and Gemini accounts.
- Background queue, live preview with agent browser, rewind, cost limits, @-mentions, learned conventions, skill builder, notifications, app icon.

## Later
- Worktree cleanup: remove merged worktrees and branches from the app (sub-sessions make this more pressing).
- Persist sub-session links across restarts, and show sub-sessions nested under their parent in the sidebar.
- HTTP and SSE MCP servers (stdio only today) and MCP resources and prompts.
- Image generation and screenshot tools for front-end work, through the vision model.
- Better token accounting: a provider tokenizer instead of the 3.5 characters per token estimate, and a context bar showing cache hits.
- Session search, export to markdown, and pinning.
- Themes, font size and a compact density setting. Syntax highlighting in diffs and file previews.
- Signed and notarised release builds with Sparkle updates.

## Known limitations
- Sub-session links live in memory: after Anvil restarts, the sub-sessions are still in the sidebar and their branches still exist, but the main session's agent can't wait for or merge them anymore (merge them from the Git tab).
- LSP checks cover the files a batch edited; errors a change causes in *other* files show up when the tests run.
- Edits made by shell commands aren't in checkpoints.
- `grep` is a Swift scan that skips common vendor and build folders but doesn't read `.gitignore`.
- The UI check on a 980 pt wide window was done on a capture of a window on another Space; the sidebar looked clipped there but may have been a stale frame.
