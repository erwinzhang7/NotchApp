# Token Usage Intake

Prototype-only scripts for validating native Claude Code and Codex usage parsing before wiring anything into NotchApp.

Run:

```bash
swift Scripts/token-usage-intake.swift --pretty
```

Optional event-level output:

```bash
swift Scripts/token-usage-intake.swift --pretty --events
```

Inputs:

- Claude Code: `CLAUDE_CONFIG_DIR` when set, otherwise `~/.config/claude/projects` and `~/.claude/projects`.
- Codex: `CODEX_HOME` when set, otherwise `~/.codex/sessions`.

The script extracts only timestamps, session IDs, model names, token counters, and cost metadata when present. It does not read prompt or response content into the output.
