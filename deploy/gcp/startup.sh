#!/usr/bin/env bash
# chum-mem VM startup script (Debian 12). Idempotent: safe to re-run on reboot.
# Installs Docker, clones the CodeChum/chum-mem fork, writes .env, and starts the
# stack with the API reachable only through IAP TCP forwarding. Access is via IAP TCP forwarding
# (gcloud compute start-iap-tunnel), so nothing is exposed to the internet.
set -euo pipefail
exec > >(tee -a /var/log/chum-mem-startup.log) 2>&1
echo "=== chum-mem startup $(date -u +%FT%TZ)"

APP_USER=chummem
APP_HOME=/opt/chum-mem
REPO_URL="https://github.com/CodeChum/chum-mem.git"

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

id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$APP_HOME" --shell /usr/sbin/nologin "$APP_USER"
usermod -aG docker "$APP_USER" || true
mkdir -p "$APP_HOME"

if [[ ! -d "$APP_HOME/src/.git" ]]; then
  git clone --depth 1 "$REPO_URL" "$APP_HOME/src"
else
  git -C "$APP_HOME/src" pull --ff-only || true
fi
chown -R "$APP_USER:$APP_USER" "$APP_HOME"

cd "$APP_HOME/src"
if [[ ! -f .env ]]; then
  # (no pipeline here: under `pipefail` a tr|head pipe exits 141/SIGPIPE and kills the script)
  PGPASS=$(openssl rand -hex 16)
  cp .env.example .env
  sed -i "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=${PGPASS}#" .env
  sed -i "s#^DATABASE_URL=.*#DATABASE_URL=postgres://chum_mem:${PGPASS}@postgres:5432/chum_mem#" .env
  sed -i "s#^VECTOR_STORE_BACKEND=.*#VECTOR_STORE_BACKEND=chroma#" .env
  grep -q '^FASTEMBED_CACHE_DIR=' .env || echo 'FASTEMBED_CACHE_DIR=/data/fastembed' >> .env
  chmod 600 .env; chown "$APP_USER:$APP_USER" .env
fi

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

# Build once (Rust, ~20-30 min on 4 vCPU), then start in the order the model
# download needs: postgres -> api (downloads the embedding model) -> worker.
docker compose build api worker web
docker compose up -d postgres
docker compose up -d api
for i in $(seq 1 60); do curl -sf --max-time 2 http://127.0.0.1:63001/ready >/dev/null 2>&1 && break; sleep 5; done
docker compose up -d worker web
curl -s http://127.0.0.1:63001/ready || true
echo "=== chum-mem startup done $(date -u +%FT%TZ)"
