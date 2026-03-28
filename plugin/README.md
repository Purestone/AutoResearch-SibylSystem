# Plugin Directory — opencode Migration Note

This directory originally contained Claude Code plugin definitions
(`plugin/.claude-plugin/`, `plugin/commands/`, `plugin/hooks/`).

## Status: Stubbed for opencode

The Claude Code plugin system (slash commands via `.claude-plugin/`, and hooks
via `hooks.json`) is **not directly supported** by `opencode`.  The command
files under `plugin/commands/` document the orchestration loop prompts and
serve as reference material; the hooks under `plugin/hooks/` are Claude Code
specific and have no direct opencode equivalent.

## Slash Commands

The `/sibyl-research:*` slash commands are implemented as orchestration loop
prompts inside `sibyl/prompts/`.  When running under `opencode`, trigger the
research loop by sending the equivalent natural-language prompt directly in the
opencode conversation, or by invoking the Python CLI:

```bash
.venv/bin/python3 -c "from sibyl.orchestrate import cli_next; cli_next('<workspace>')"
```

## Hooks

The `plugin/hooks/` scripts relied on Claude Code's `PostToolUse` and
`UserPromptSubmit` hook events.  opencode does not provide the same hook
mechanism.  Background daemons (e.g., experiment monitoring) must be launched
manually or via tmux rather than through agent hooks.

## Commands reference

The markdown files in `plugin/commands/` still contain useful prompt
documentation and are kept as human-readable references.
