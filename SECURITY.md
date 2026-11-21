# Security policy

Anvil runs commands and edits files on your Mac, and stores API keys and session cookies in the Keychain, so security problems matter.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's [private vulnerability reporting](../../security/advisories/new) for this repository instead, with:

- what the problem is and what an attacker could do with it,
- steps to reproduce,
- the Anvil version or commit.

You'll get a reply within a few days, and credit in the fix if you want it.

## Worth reporting

- A way for file contents, command output or web pages to make the agent act without the permission policy (prompt injection that bypasses approvals).
- Dangerous commands that run without asking outside Bypass mode.
- Keys or cookies leaking into logs, commands the agent runs, or network requests to anyone but the provider.

Bypass mode deliberately runs everything without asking, so "Bypass ran a command" isn't a vulnerability.
