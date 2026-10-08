# chum-mem for GradeChum engineers — setup

Status 2026-10-08: the memory logic is verified (see FINDINGS.md), but **no shared
server is deployed yet**. Until the server step below is done, the only working
instance is a local Docker stack on one laptop. Do steps 1–2 once as a team,
then every engineer does step 3.

## 1. Server (once, needs an owner)

Target: Mac Studio proof of concept (runbook in FINDINGS.md) or a GCP VM. In short:

```bash
gh repo clone CodeChum/chum-mem && cd chum-mem
cp .env.example .env            # change POSTGRES_PASSWORD + DATABASE_URL, keep ports on 127.0.0.1
# VECTOR_STORE_BACKEND=chroma  -> pgvector path (recommended; no Chroma service needed)
# FASTEMBED_CACHE_DIR=/data/fastembed
docker compose up -d postgres
docker compose up -d api        # downloads the embedding model (~1 min) — start API first
docker compose up -d worker     # then the worker (concurrent first-run downloads corrupt the model copy)
curl -s localhost:63001/ready
```

Expose it **only** behind access control: a Cloudflare Tunnel ingress for
`chum-mem.<domain>` → `http://localhost:63001` plus a Cloudflare Access policy
limited to the engineers' emails. The API itself has no authentication
(FINDINGS F5). Verify an unauthenticated `curl` is rejected before step 3.

Open item for the hooks: the plugin's `curl` calls must carry Access
credentials (Cloudflare WARP on each laptop, or a service token added to the
hook scripts). Pick one before rolling out.

## 2. Monorepo (once)

Merge branch `chum-mem-pilot/shared-project-id` in `CodeChum/gradechum`. It adds:

- `.chum-mem` — the shared project id (every checkout joins one graph)
- `.chum-sync-rules.json` — docs-only sync rules (the server cannot index the
  18k-file monorepo yet, FINDINGS F8); the plugin prefers this file
- `docs-mirror/` — memory notes mirrored as repository docs
- `.gitignore` — `.chum-cache/`

Backfill history once from each engineer's machine (cheap, FINDINGS F10):

```bash
cd chum-mem && pnpm install
pnpm sessions:import --roots ~/.claude/projects/<your-monorepo-folders> \
  --server https://chum-mem.<domain> --project $(jq -r .projectId <monorepo>/.chum-mem) --yes
```

Then call `POST /api/admin/reembed {"projectId": ...}` once.

## 3. Each engineer (5 minutes)

```bash
export CHUM_MEMORY_API_URL=https://chum-mem.<domain>   # add to your shell profile
gh repo clone CodeChum/chum-mem ~/chum-mem
cd ~/chum-mem && ./plugin-install.sh claude production
```

Then start Claude Code from the **monorepo root** (the hooks resolve the project
id from `.chum-mem` there). Check it works:

- `/mcp` shows `chum-memory` connected
- a prompt such as "is anyone working on the bonus toggle?" answers from team
  memory with the author's email
- `.chum-cache/` appears in the repo root (ignored); if the server is down,
  events spool to `.chum-cache/outbox/` and replay on the next prompt

Identity is your git `user.email` in that checkout — make sure it is your work
address.

## What you get, and what you do not (yet)

- Every prompt is auto-searched against team memory; hits are injected with
  author, time and session (FINDINGS F29). Decisions, fixes and open questions
  from any engineer's sessions are findable within seconds of their session
  ending (F20, F28).
- Repository docs (CLAUDE files, rules, notes) are searchable; the code graph of
  the monorepo is **not** indexed until F8 is fixed server-side.
- Transcripts are stored raw with no redaction (team decision); the server's
  access control is the only gate.
- Headless `claude -p` runs capture no prompt on some Claude Code versions (F9).
