---
name: chum-quarantine
description: "Review, release or discard session events that the chum-mem sensitive-content guard held back from team memory. Use when a hook warning says an item was NOT sent to team memory, or when the user asks what is held. Args: list | send [SESSION] | drop [SESSION]."
user-invocable: true
---

# chum-quarantine

The hooks scan every prompt, tool output and reply for secret-shaped strings
(API keys, tokens, passwords in URLs, private keys, JWTs, `KEY=value` secrets).
A match is **held** in `.chum-cache/quarantine/` instead of being sent, and a
warning line tells the user. Held items are never sent on their own.

Run the script with the user's argument (default `list`) and show its output:

```bash
bash "$(git rev-parse --show-toplevel)/.claude/chum-mem/scripts/chum-quarantine.sh" <list|send|drop> [SESSION]
```

If that path does not exist, use `${CLAUDE_PLUGIN_ROOT}/scripts/chum-quarantine.sh`.

Rules:
- `list` masks the secrets. Never print a held item's raw content yourself and
  never read the quarantine files directly.
- `send` releases the items to team memory as they are (the team store has no
  redaction). Only do it when the user explicitly asks to send.
- `drop` discards them permanently.
- A `SESSION` argument is the id prefix printed by `list`; without it the
  command acts on everything held in this checkout.
