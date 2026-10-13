#!/usr/bin/env bash
# chum-mem VM startup script (Debian 12). Runs on every boot.
#
#   First boot: installs Docker, clones the CodeChum/chum-mem fork at the ref
#     in instance metadata `chum-mem-ref` (deploy-vm.sh create pins it to a
#     commit; default `main`), writes .env with generated secrets (Postgres
#     password, team API token, admin token), builds and starts the stack.
#   Later boots: starts the stack that is already checked out and built. It
#     never fetches, pulls or rebuilds, so a reboot cannot deploy unreviewed code.
#   Deploy a reviewed ref explicitly (from a laptop):
#     deploy/gcp/deploy-vm.sh deploy <commit-or-tag>
#   which runs this script as `startup.sh --deploy <ref>`.
#
# The API is reachable only through IAP TCP forwarding (gcloud compute
# start-iap-tunnel); nothing is exposed to the internet. Secrets are written to
# .env (mode 600) and never echoed: this script's output goes to
# /var/log/chum-mem-startup.log.
set -euo pipefail
exec > >(tee -a /var/log/chum-mem-startup.log) 2>&1
echo "=== chum-mem startup $(date -u +%FT%TZ) ${*:-}"

APP_USER=chummem
APP_HOME=/opt/chum-mem
REPO_URL="https://github.com/CodeChum/chum-mem.git"

MODE=boot
DEPLOY_REF=""
if [[ "${1:-}" == "--deploy" ]]; then
  MODE=deploy
  DEPLOY_REF="${2:-}"
  [[ -n "$DEPLOY_REF" ]] || { echo "usage: startup.sh --deploy <ref>"; exit 2; }
fi

metadata_attr() {  # $1 attribute name; empty when unset or off GCP
  curl -sf --max-time 5 -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2>/dev/null || true
}

valid_ref() {  # a branch, tag or commit; nothing a shell or git could misread
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ && "$1" != -* && "$1" != *..* ]]
}

if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl gnupg git jq openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# Root runs git on a checkout owned by $APP_USER. Without this git refuses
# ("dubious ownership"), the HEAD check below fails, a reboot is taken for a
# first boot and the script dies before starting the stack.
git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$APP_HOME/src" \
  || git config --system --add safe.directory "$APP_HOME/src"

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
usermod -aG docker "$APP_USER" || true
mkdir -p "$APP_HOME"

checkout_ref() {  # $1 ref: fetch exactly that ref and check it out detached
  if [[ "$1" =~ ^[0-9a-f]{7,39}$ ]]; then
    echo "ref $1 looks like an abbreviated commit; use the full 40-character SHA (git fetch cannot resolve short SHAs)"
    exit 2
  fi
  git -C "$APP_HOME/src" fetch --depth 1 origin "$1"
  git -C "$APP_HOME/src" checkout --detach --force FETCH_HEAD
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$1" "$(git -C "$APP_HOME/src" rev-parse HEAD)" >> "$APP_HOME/deployed-refs.log"
  echo "checked out $1 at $(git -C "$APP_HOME/src" rev-parse --short HEAD)"
}

BUILD=0
# "First boot" = no checked-out commit yet (also covers a first boot that died
# half-way, which leaves a .git without HEAD).
if ! git -C "$APP_HOME/src" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  REF="$(metadata_attr chum-mem-ref)"
  REF="${REF:-main}"
  valid_ref "$REF" || { echo "invalid chum-mem-ref metadata value"; exit 1; }
  git init -q "$APP_HOME/src"
  git -C "$APP_HOME/src" remote remove origin >/dev/null 2>&1 || true
  git -C "$APP_HOME/src" remote add origin "$REPO_URL"
  checkout_ref "$REF"
  BUILD=1
elif [[ "$MODE" == "deploy" ]]; then
  valid_ref "$DEPLOY_REF" || { echo "invalid ref: $DEPLOY_REF"; exit 2; }
  checkout_ref "$DEPLOY_REF"
  BUILD=1
else
  echo "existing checkout at $(git -C "$APP_HOME/src" rev-parse --short HEAD); not fetching (deploy with deploy-vm.sh deploy <ref>)"
fi
chown -R "$APP_USER:$APP_USER" "$APP_HOME"

cd "$APP_HOME/src"

# ── .env and secrets ─────────────────────────────────────────────────────────
# Values are produced by `openssl rand` into a variable and written with the
# printf builtin, so a secret never appears in a process argument list or in
# the log. No pipelines: under `pipefail` a tr|head pipe exits 141 (SIGPIPE).
env_value() {  # $1 key -> current value in .env (may be empty)
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$1="* ]]; then printf '%s' "${line#*=}"; return 0; fi
  done < .env
  return 0
}
set_env_value() {  # $1 key, $2 value: replace KEY=... or append it
  local key="$1" value="$2" line found=0 tmp
  tmp="$(mktemp .env.XXXXXX)"
  chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value" >> "$tmp"; found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < .env
  [[ "$found" -eq 1 ]] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv -f "$tmp" .env
}
ensure_secret() {  # $1 key: generate a value when the key is missing or empty
  if [[ -z "$(env_value "$1")" ]]; then
    set_env_value "$1" "$(openssl rand -hex 32)"
    echo "generated $1 in $APP_HOME/src/.env"
  fi
}

if [[ ! -f .env ]]; then
  ( umask 077; cp .env.example .env )
  PGPASS="$(openssl rand -hex 16)"
  set_env_value POSTGRES_PASSWORD "$PGPASS"
  set_env_value DATABASE_URL "postgres://chum_mem:${PGPASS}@postgres:5432/chum_mem"
  set_env_value VECTOR_STORE_BACKEND chroma
  [[ -n "$(env_value FASTEMBED_CACHE_DIR)" ]] || set_env_value FASTEMBED_CACHE_DIR /data/fastembed
  unset PGPASS
fi
chmod 600 .env
# Auth is never left off: .env.example ships these empty, and the API refuses
# to start with no team token (CHUM_MEM_ALLOW_NO_AUTH is not set here).
ensure_secret CHUM_MEM_API_TOKENS
ensure_secret CHUM_MEM_ADMIN_TOKENS
if [[ -z "$(env_value CHUM_MEMORY_API_TOKEN)" ]]; then
  # The dashboard calls the API with the first team token.
  TEAM_TOKENS="$(env_value CHUM_MEM_API_TOKENS)"
  set_env_value CHUM_MEMORY_API_TOKEN "${TEAM_TOKENS%%,*}"
  unset TEAM_TOKENS
fi
if [[ -n "$(env_value CHUM_MEM_ALLOW_NO_AUTH)" ]]; then
  echo "WARNING: CHUM_MEM_ALLOW_NO_AUTH is set in .env; remove it on a shared server"
fi
chmod 600 .env; chown "$APP_USER:$APP_USER" .env

# Postgres and the dashboard bind to loopback. The API binds to the VM's
# INTERNAL NIC address: IAP TCP forwarding connects to that address, not to
# loopback, and the firewall admits only Google's IAP range on 63001.
INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
cat > docker-compose.override.yml <<YML
services:
  postgres:
    ports: !override
      - "127.0.0.1:65432:5432"
  api:
    ports: !override
      - "${INTERNAL_IP}:63001:63001"
    deploy:
      resources:
        limits:
          memory: 8g
  worker:
    deploy:
      resources:
        limits:
          memory: 4g
  web:
    ports: !override
      - "127.0.0.1:63000:63000"
YML

# ── Nightly backup ───────────────────────────────────────────────────────────
# With instance metadata `chum-mem-backup-bucket` set (deploy-vm.sh
# enable-backups), a timer dumps Postgres at 18:30 UTC (02:30 PHT) to
# gs://<bucket>/postgres/. Defined here rather than in the checkout because the
# checkout only changes on a deploy, while this script is refreshed in metadata.
# The VM's service account may only create objects in that bucket: no read,
# overwrite or delete, so a compromised VM cannot destroy earlier backups.
if [[ -n "$(metadata_attr chum-mem-backup-bucket)" ]]; then
  cat > /usr/local/sbin/chum-mem-backup <<'SH'
#!/usr/bin/env bash
# Dumps to local disk first, so a pg_dump that fails stops the script before
# anything is uploaded, and an archive pg_restore cannot read is never uploaded.
set -euo pipefail
BUCKET="$(curl -sf --max-time 5 -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/chum-mem-backup-bucket)"
NAME="chum-mem-$(date -u +%Y%m%dT%H%M%SZ).dump"
DUMP="$(mktemp /var/tmp/chum-mem-backup.XXXXXX)"
trap 'rm -f "$DUMP"' EXIT
cd /opt/chum-mem/src
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' > "$DUMP"
docker compose exec -T postgres pg_restore --list < "$DUMP" > /dev/null
# The JSON API, not `gcloud storage cp`: gcloud reads the object first, which
# a create-only account may not. ifGenerationMatch=0 refuses to overwrite.
TOKEN="$(curl -sf --max-time 5 -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)"
RESP="$(curl -sS --fail-with-body --retry 3 -X POST --data-binary @"$DUMP" \
  -H 'Content-Type: application/octet-stream' -H @/dev/fd/9 \
  "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&ifGenerationMatch=0&name=postgres%2F$NAME" \
  9<<<"Authorization: Bearer $TOKEN")" || { echo "upload failed: $RESP" >&2; exit 1; }
unset TOKEN
echo "uploaded gs://$BUCKET/postgres/$NAME ($(printf '%s' "$RESP" | jq -r .size) bytes)"
SH
  chmod 0755 /usr/local/sbin/chum-mem-backup
  cat > /etc/systemd/system/chum-mem-backup.service <<'UNIT'
[Unit]
Description=chum-mem Postgres backup to Cloud Storage
After=docker.service google-startup-scripts.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/chum-mem-backup
UNIT
  cat > /etc/systemd/system/chum-mem-backup.timer <<'UNIT'
[Unit]
Description=Nightly chum-mem Postgres backup

[Timer]
OnCalendar=*-*-* 18:30:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now chum-mem-backup.timer
  echo "nightly backup timer enabled ($(metadata_attr chum-mem-backup-bucket))"
fi

# Build only on first boot or an explicit deploy (Rust, ~20-30 min on 4 vCPU).
# A plain reboot reuses the images built from the checked-out commit. Then start
# in the order the model download needs: postgres -> api (downloads the
# embedding model) -> worker.
if [[ "$BUILD" -eq 1 ]]; then
  docker compose build api worker web
fi
docker compose up -d postgres
docker compose up -d api
for i in $(seq 1 60); do curl -sf --max-time 2 "http://${INTERNAL_IP}:63001/ready" >/dev/null 2>&1 && break; sleep 5; done
docker compose up -d worker web
curl -s "http://${INTERNAL_IP}:63001/ready" || true
echo
echo "=== chum-mem startup done $(date -u +%FT%TZ) (commit $(git rev-parse --short HEAD))"
