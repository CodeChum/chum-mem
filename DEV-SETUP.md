# chum-mem for GradeChum engineers — setup

Status 2026-10-08: the memory logic is verified (see FINDINGS.md) and a shared
server is deployed on GCP (step 1). Do step 2 once as a team, then every
engineer does step 3.

## 1. Server (deployed 2026-10-08: GCP VM `gradechum-chum-mem`)

Project `gradechum`, zone `asia-east1-b`, e2-standard-4, Debian 12, built from
`deploy/gcp/startup.sh`. **Nothing is exposed to the internet**: the firewall
admits only Google's IAP range on tcp/22, and the API, Postgres and dashboard
bind to the VM's loopback. Access control is Google IAM on the project.

Operate it with `deploy/gcp/deploy-vm.sh` (`status`, `logs`, `ssh`, `tunnel`):

```bash
export CHUM_GCP_ZONE=asia-east1-b CHUM_GCP_VM=gradechum-chum-mem
deploy/gcp/deploy-vm.sh logs     # startup/build log
deploy/gcp/deploy-vm.sh ssh      # IAP SSH; the stack lives in /opt/chum-mem/src
```

Engineers need the IAM role **IAP-secured Tunnel User** (`roles/iap.tunnelResourceAccessor`)
plus `compute.instances.get` on the project (Compute Viewer is enough).

If you ever want to re-create it: `deploy/gcp/deploy-vm.sh create` (same env vars).

## 2. Monorepo (once)

Branch `chum-mem-pilot/shared-project-id` was merged into `main` on 2026-10-09. It adds:

- `.chum-mem` — the shared project id (every checkout joins one graph)
- `.chum-sync-rules.json` — docs-only sync rules (the server cannot index the
  18k-file monorepo yet, FINDINGS F8); the plugin prefers this file
- `docs-mirror/` — memory notes mirrored as repository docs
- `.gitignore` — `.chum-cache/`

The store was reset to empty on 2026-10-09 (the earlier full import was for
testing only); the team starts from scratch and nothing is backfilled by
default. If a backfill is ever wanted, do it **on the VM over SSH**, not through
the IAP tunnel: a tunnel reset mid-import leaves sessions partial and the
bulk-import indexes dropped (FINDINGS F31). Copy the transcript folders up, then:

```bash
# on your laptop: copy your monorepo session folders to the VM
gcloud compute scp --recurse --tunnel-through-iap --zone=asia-east1-b --project=gradechum \
  ~/.claude/projects/-Users-<you>-gradechum-gradechum* gradechum-chum-mem:/tmp/sessions/
# on the VM (deploy/gcp/deploy-vm.sh ssh), from /opt/chum-mem/src:
CHUM_IMPORT_EMAIL=<you>@codechum.com pnpm sessions:import --roots /tmp/sessions \
  --server http://10.140.0.9:63001 --project $(jq -r .projectId <monorepo>/.chum-mem) --yes
curl -s -X POST -H 'Content-Type: application/json' -d '{"projectId":"<id>"}' http://10.140.0.9:63001/v1/ingest/bulk/create-indexes
```

Embeddings are computed on ingest with the local model, so no re-embed step is
needed on the VM (`POST /api/admin/reembed` exists for model changes).
`CHUM_IMPORT_EMAIL` stamps the imported sessions with your identity (otherwise
the importer's git `user.email`); without it recall shows "by unknown".

Commit `.chum-sync-rules.json` with the branch: a checkout without it syncs
all code and rewrites the shared repository snapshot for everyone.

## 3. Each engineer (one-time, about 3 minutes)

The hooks, the retrieval skill and the MCP server are **committed in the
monorepo** (`.claude/settings.json`, `.claude/chum-mem/`, `.claude/skills/chum-memory/`,
`.mcp.json`, `.chum-mem`), so there is no plugin to install. The only thing a
laptop needs is the tunnel to the VM:

On the laptop you need the Google Cloud SDK (`brew install --cask google-cloud-sdk`),
the GitHub CLI logged in (`brew install gh && gh auth login`; `CodeChum/chum-mem`
is private, so the clone below fails with HTTP 401 without it), and `jq` (ships
with macOS 15+, otherwise `brew install jq`; every hook uses it). Then:

```bash
gcloud auth login                                   # once; your @codechum.com account
gh repo clone CodeChum/chum-mem ~/chum-mem           # needs gh auth login first
~/chum-mem/deploy/gcp/install-tunnel-agent.sh install   # launchd agent, auto-restarts, survives reboots
~/chum-mem/deploy/gcp/install-tunnel-agent.sh token     # paste the team API token (not echoed)
```

Prerequisites from an admin: **IAP-secured Tunnel User** + **Compute Viewer** on
project `gradechum`, and the **API token** (the server rejects requests without
it since 2026-10-09). The token step stores it in `~/.config/chum-mem/token`
(0600) for the hooks and exports it from `~/.zshenv` for the MCP server; open a
new terminal afterwards. If your login shell is bash, add the same `export`
line to `~/.bash_profile` (the hooks read the file, so capture works either
way, but the MCP server only sees the env var and shows `failed` in `/mcp`
without it).

The installer is macOS-only (launchd). On Linux keep
`~/chum-mem/deploy/gcp/deploy-vm.sh tunnel` running under systemd or tmux and
do the `token` step by hand: write the token to `~/.config/chum-mem/token`
(mode 0600) and export `CHUM_MEMORY_API_TOKEN` from your shell profile.

Then start Claude Code from the **monorepo root** as usual. On the first run
Claude Code asks you to trust the folder and once to approve the project's MCP
server (`chum-memory`); accept both. (Headless `claude -p` skips the trust
dialog: in a checkout you never opened interactively it prints "Ignoring N
permissions.allow entries … has not been trusted", but the chum-mem hooks
still run.) From then on every session is captured and auto-searched,
including headless `claude -p` runs started in the repo (scripts, CI, skills
that spawn `claude -p`). If the tunnel is down, events spool to
`.chum-cache/outbox/` and replay later.

Do **not** also install the chum-memory plugin in this checkout: the committed
hooks and the plugin would both fire and every event would be stored twice.

Check (works on an empty store): `~/chum-mem/deploy/gcp/install-tunnel-agent.sh status`
shows `/ready`; in Claude Code `/mcp` shows `chum-memory` connected. Then, in
one session, type `Decision: for the chum-mem setup check I am using <your
name> as the test value.` and end the session; start a new session in the same
checkout and ask `did anyone decide what test value to use for the chum-mem
setup check?` The answer should quote the decision and name your git
`user.email`. If it does not, the session was not stored: see the
troubleshooting list below.
Identity is your git `user.email` in that checkout.

Troubleshooting (the hooks are silent on purpose, so none of these show an
error in Claude Code):

- `status` shows `/ready` but nothing is stored and `/mcp` shows `failed`:
  the token is missing or wrong. `/health` and `/ready` are open endpoints, so
  the tunnel check passes without a token. Re-run the `token` step, open a new
  terminal, and confirm with
  `curl -s -o /dev/null -w '%{http_code}\n' -H "X-Chum-Token: $(cat ~/.config/chum-mem/token)" http://localhost:63001/api/dashboard/summary`
  (expect `200`; `401` means the token is wrong).
- `status` shows nothing after `state = running`: the tunnel process is up but
  IAP refused it; check `~/Library/Logs/chum-mem-tunnel.log` and your IAM roles.
- Files pile up in `.chum-cache/outbox/`: the API was unreachable when those
  turns ran; they replay on the next hook once the tunnel is back.
- `.chum-cache/quarantine/` is not empty: the sensitive-content guard held
  something; run `/chum-quarantine list`.

Pausing capture for a session (say you are pasting customer data): start
Claude Code with `CHUM_MEMORY_API_URL=http://127.0.0.1:1 claude`. Every event
then goes to the local outbox, which is pinned to that dead URL and never
replays. Delete those outbox files when you are done. Turning the hooks off for
good in your checkout means `"disableAllHooks": true` in
`.claude/settings.local.json` (the monorepo does not gitignore it, so do not commit it). Tell the team if you do
this, because your sessions will stop showing up for everyone else.

If the tunnel is slow (several sessions share it), the hooks' health gate can be
widened per repo with `"healthTimeoutSecs": 8` in `.chum-mem` (default 5 s); a
tripped gate spools the whole turn instead of sending it live.

Auto-recall (the "Team memory" block on every prompt) shows up to 5 hits chosen
from a pool of 20 candidates; a hit must have semantic similarity >= 0.7 plus a
word in common with the prompt, or a lexical match, or share 30% of the prompt's
content words. Knobs: `CHUM_AUTO_RECALL_LIMIT`, `CHUM_AUTO_RECALL_POOL`,
`CHUM_AUTO_RECALL_MIN_SEMANTIC`. A hit whose title repeats your own question is
dropped (every prompt is also stored as an "open question" memory).

If you have a global hook that spawns `claude -p` (for example a session
labeller), guard it with an env flag: the nested session fires the project hooks
again and is captured as a junk session under your email (go-live review: 34 of
82 sessions stored in 100 minutes were labeller prompts). A minimal guard at
the top of such a hook:

```bash
[ -n "${IN_LABELLER:-}" ] && exit 0        # nested run: do nothing
export IN_LABELLER=1                        # set before calling claude -p
cd "$HOME"                                  # run the nested claude outside the repo
```

What you will notice day to day: each prompt waits about 1–2 s for the hooks
on an idle server (4–8 s when the server or tunnel is busy), each tool call
about 0.25 s, and the reply stays on screen while the Stop hook finishes. The
"Team memory" block is often filled with shell commands and paths from recent
sessions rather than decisions; it is only useful when someone recorded a
decision or fix in words ("Decision: …", "Fixed: …").

Token auth is **on** (`CHUM_MEM_API_TOKENS` in the VM's `.env`; one shared team
token for the pilot, comma-separated list for more). Rotate by editing `.env`
and `docker compose up -d`, then re-run the `token` step on every laptop.

## Sensitive-content guard (hold and ask)

Claude Code hooks cannot open a dialog, so the guard works as hold-and-ask.
Every prompt, tool output and reply is scanned against
`scripts/sensitive-patterns.txt` (API keys, OAuth tokens, passwords inside
URLs, private keys, JWTs, webhook URLs, `KEY=value` secrets). A match is
**held** in `.chum-cache/quarantine/` instead of being sent, and the hook shows
one warning line:

> chum-mem: NOT sent to team memory — secret-shaped content (anthropic-key)
> found in your prompt. … Run /chum-quarantine list / send / drop.

Held items are never sent on their own. `/chum-quarantine list` shows them with
the secrets masked, `send` releases them as they are (the store has no
redaction), `drop` discards them. A session whose reply was held still closes
normally with a placeholder summary. Clean events are not delayed; the scan is
a few `grep -E` calls per event.

Expect false positives when reading ordinary code: the generic
`secret-assignment` rule matches lines such as `auth_token = request…` or
`SECRET_KEY = os.getenv(…)`, so a session that reads
`gradechum-api/gradechum/tasks/views/tasks.py` or `settings.py` gets the warning
and those tool results stay local (go-live review, runs 800 and 805; a narrower
rule is proposed). Run `/chum-quarantine list` and `send` if nothing in it is a
real secret.

The list is a starting point, not a policy. Extend it per repo with a
`.chum-sensitive-patterns` file at the repo root (same `name|flags|regex`
format); both lists apply. `CHUM_SENSITIVE_GUARD=0` disables the scan.
The docs sync (`sync.sh`) is not scanned yet; committed docs are the team's
responsibility.

## Scope decision (2026-10-09)

- Laptop sessions in the monorepo: captured. Cloud / web Claude Code sessions,
  Claude Desktop and Cowork: **not captured** (no tunnel, no hooks there). The
  public-hostname path (Cloudflare Tunnel + Access + API token) is built but
  not deployed; it is the next step if cloud sessions are wanted.

## What you get, and what you do not (yet)

- Every prompt is auto-searched against team memory; hits are injected with
  author, time and session (FINDINGS F29). Decisions, fixes and open questions
  from any engineer's sessions are findable within seconds of their session
  ending (F20, F28).
- Repository docs (CLAUDE files, rules, notes) are searchable; the code graph of
  the monorepo is **not** indexed until F8 is fixed server-side.
- Transcripts are stored raw with no redaction (team decision); the server's
  access control is the only gate.
- Headless `claude -p` runs captured no prompt on older Claude Code versions
  (F9); on 2.1.x the prompt, every tool result and the reply are captured
  (go-live review, runs 800–809).

## Changing the hook scripts (maintainers)

`.claude/chum-mem/scripts/` in the monorepo is a byte copy of
`plugins/chum-memory-claude/scripts/` in this repo; change the fork first and
copy. To point a checkout at another server (a local stack, a review VM) export
`CHUM_MEMORY_API_URL` before starting Claude Code: the hooks and the root
`.mcp.json` both read it, and `.chum-mem` carries no `apiUrl` on purpose. (The
hook's own `.mcp.json` rewrite targets `.claude/chum-mem/.mcp.json`, which does
not exist in the monorepo layout, so it is a no-op there.) Before any paid
session, run the three-event dry run against the server
and confirm the session row on it (this caught a silent `set -e` exit that lost
3.5 hours of capture during the overnight test, FINDINGS F39):

```bash
R=<checkout>; for ev in SessionStart UserPromptSubmit Stop; do
  jq -n --arg r "$R" --arg ev $ev '{session_id:"dry-1",hook_event_name:$ev,cwd:$r,prompt:"dry run",last_assistant_message:"ok",source:"startup"}' \
  | CHUM_MEMORY_API_URL=http://localhost:63001 CLAUDE_PROJECT_DIR=$R bash $R/.claude/chum-mem/scripts/hook-dispatch.sh; done
# expect on the server: sessions.external_session_id='dry-1', status completed, metadata.userEmail set, events prompt+response
```
