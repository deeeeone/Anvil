# Roadmap

## Next
- **Streaming replies.** Stream tokens so the reasoning and `say` appear as they're written. Fall back to non-streaming for providers without SSE.
- **Per-hunk review.** Accept or reject individual hunks in a diff, and edit the proposed text before applying it.
- **Shell checkpoints.** Snapshot the git working tree (a stash-like commit) before shell commands in auto modes, so undo covers changes those commands make too.
- **Persistent allow rules.** Project-level `.anvil/settings.json` allow and deny lists for commands (like Claude Code's permissions), on top of today's session allow list.
- **Hooks.** Run user commands before and after tool calls (format on save, lint after edit, block patterns).

## Later
- Subagents: parallel read-only investigators that report back a summary, to save context on big codebases.
- Git worktree sessions: run a session on its own branch and worktree, then merge or open a PR.
- A `gh` integration: PR creation, review comments into the chat, CI status.
- An LSP bridge for diagnostics after edits (Swift, TypeScript, Python), fed into observations.
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
