> **⚠ Deprecated for opencode**: This tool relies on Claude Code's internal
> cache files (`~/.claude/micucodeline/...`) and the Claude Code
> `UserPromptSubmit` hook mechanism.  Neither of these exists in `opencode`.
> The tool is kept here for reference but **will not work** with opencode.
> Remove or ignore this directory when running the Sibyl system under opencode.

# Claude Quota Guard

`Claude Quota Guard` is a small Claude Code plugin that uses the official `UserPromptSubmit` hook to pause new prompts whenever your local quota snapshot says the remaining budget is below a configured threshold.

It is designed around two ideas:

1. A real plugin hook for request gating.
2. A separate `statusLine` helper command for showing the current quota snapshot.

## What It Uses

The plugin does not call any private Claude endpoint by itself. Instead it reads local files that already exist on the machine:

- `~/.claude/micucodeline/.api_usage_cache.json`
- `~/.claude/micucodeline/cache/balance_*.json`

That makes it safe to run before every prompt without recursively consuming quota.

## Why Poll Instead Of Sleeping Until `resets_at`

The local cache may expose a `resets_at` value, but depending on the upstream provider that timestamp can describe a weekly limit instead of the rolling five-hour window.

So the hook does not blindly sleep until `resets_at`. It enters a polling loop:

1. Read the latest local quota snapshot.
2. If remaining quota is below the threshold, wait `CLAUDE_QUOTA_GUARD_POLL_SECONDS`.
3. Re-read the snapshot.
4. Continue until the threshold is healthy again.

This is safer than trusting a single reset timestamp.

## Files

- `.claude-plugin/plugin.json`: plugin metadata
- `hooks/hooks.json`: registers the `UserPromptSubmit` hook
- `scripts/quota-guard.mjs`: hook entrypoint and manual checker
- `scripts/statusline.mjs`: optional status line command
- `scripts/lib/quota-guard-lib.mjs`: shared quota-reading logic

## Configuration

Environment variables:

- `CLAUDE_QUOTA_GUARD_MIN_FIVE_HOUR_REMAINING_PERCENT`
  Default: `5`
- `CLAUDE_QUOTA_GUARD_MIN_BALANCE`
  Optional absolute balance threshold
- `CLAUDE_QUOTA_GUARD_MIN_BALANCE_REMAINING_PERCENT`
  Optional fallback percentage threshold for `balance/total`
- `CLAUDE_QUOTA_GUARD_POLL_SECONDS`
  Default: `60`
- `CLAUDE_QUOTA_GUARD_MAX_WAIT_SECONDS`
  Default: `0` for unlimited waiting
- `CLAUDE_QUOTA_GUARD_FAIL_OPEN`
  Default: `true`
- `CLAUDE_QUOTA_GUARD_STALE_USAGE_SECONDS`
  Default: `900`
- `CLAUDE_QUOTA_GUARD_USAGE_CACHE_FILE`
  Override the usage cache file path
- `CLAUDE_QUOTA_GUARD_BALANCE_FILE`
  Override the balance file path
- `CLAUDE_QUOTA_GUARD_BALANCE_CACHE_DIR`
  Override the balance cache directory
- `CLAUDE_QUOTA_GUARD_STATE_DIR`
  Default: `~/.claude/quota-guard`

## Local Development

Validate the plugin:

```bash
claude plugin validate /Users/cwan0785/sibyl-system/tools/claude-quota-guard
```

Run it in a session without installing into a marketplace:

```bash
claude --plugin-dir /Users/cwan0785/sibyl-system/tools/claude-quota-guard
```

Manual dry-run:

```bash
node scripts/quota-guard.mjs --check
node scripts/quota-guard.mjs --summary
printf '{"model":{"display_name":"Sonnet"},"workspace":{"current_dir":"/tmp/demo"}}\n' | node scripts/statusline.mjs
```

## Status Line

Claude Code plugins can bundle hooks, but `statusLine` still needs to be configured in Claude settings. Use [`examples/settings.snippet.json`](/Users/cwan0785/sibyl-system/tools/claude-quota-guard/examples/settings.snippet.json) as the starting point.

## Other Possible Approaches

I explored a few alternatives while building this:

1. Calling Claude or `/rate-limit-options` from the hook itself.
   This would be recursive and can itself consume quota, so I rejected it.
2. Trusting `resets_at` and sleeping until that exact time.
   Too risky because some caches appear to mix five-hour and seven-day limits.
3. Calling a private upstream API directly.
   Higher maintenance risk and not portable across Anthropic-hosted Claude Code versus third-party gateways.

The current plugin is intentionally conservative: it uses local snapshots, shows the reset time when available, and waits by polling instead of guessing.
