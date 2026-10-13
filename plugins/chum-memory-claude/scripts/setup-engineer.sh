#!/usr/bin/env bash
# setup-engineer.sh — one-command chum-mem setup for a GradeChum engineer (macOS).
#
# Run it from a Claude Code session in the monorepo, after an admin has added
# you (`deploy/gcp/deploy-vm.sh add-user you@codechum.com` in the chum-mem repo):
#
#   ! bash .claude/chum-mem/scripts/setup-engineer.sh
#
# Your personal token is read from your own Secret Manager secret (only your
# Google account can read it), checked against the server and saved to
# ~/.config/chum-mem/token (0600). It is never printed and never typed into
# the Claude prompt (prompts are captured). The server credits your memories
# to the token's owner, your Google account.
#
# Steps, each skipped when already done: jq + Google Cloud SDK (Homebrew),
# `gcloud auth login` (browser), the launchd IAP tunnel agent on
# localhost:63001, a launchd connection check that shows a dialog with the fix
# (sign in / set up) whenever chum-mem is not connected, the token, the MCP env var in ~/.zshenv. Safe to re-run;
# re-run after an admin rotates your token.
#
# Env: CHUM_TOKEN_FILE=<path>  read the token from a file instead of Secret Manager
#      CHUM_SETUP_LABEL / CHUM_AUTH_CHECK_LABEL / CHUM_LOCAL_PORT  launchd labels / local port (tests)
set -uo pipefail
# Bump whenever what this script installs changes (launchd jobs, their settings,
# the copied tunnel-auth-check.sh). The hook compares it with the version this
# script last recorded in ~/.config/chum-mem/setup-version and offers to re-run.
SETUP_VERSION=2
PROJECT="${CHUM_GCP_PROJECT:-gradechum}"
ZONE="${CHUM_GCP_ZONE:-asia-east1-b}"
VM="${CHUM_GCP_VM:-gradechum-chum-mem}"
PORT="${CHUM_LOCAL_PORT:-63001}"
LABEL="${CHUM_SETUP_LABEL:-com.codechum.chum-mem-tunnel}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
TOKEN_DIR="$HOME/.config/chum-mem"
TOKEN_FILE="$TOKEN_DIR/token"
AUTH_LABEL="${CHUM_AUTH_CHECK_LABEL:-com.codechum.chum-mem-auth-check}"
AUTH_PLIST="$HOME/Library/LaunchAgents/$AUTH_LABEL.plist"
AUTH_CHECK="$TOKEN_DIR/tunnel-auth-check.sh"
API="http://localhost:$PORT"
ok()   { printf '  ok    %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
fail() { printf '\n  FAILED: %s\n' "$*"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only. On Linux follow DEV-SETUP.md section 3 by hand."
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" && -f "$ROOT/.chum-mem" ]] || fail "run this from the gradechum monorepo (no .chum-mem found)."

step "1/6 tools"
need_brew() { command -v brew >/dev/null 2>&1 || fail "Homebrew is needed to install $1: https://brew.sh"; }
if command -v jq >/dev/null 2>&1; then ok "jq"; else need_brew jq; brew install jq >/dev/null || fail "brew install jq"; ok "jq installed"; fi
GCLOUD="$(command -v gcloud || true)"
for p in /opt/homebrew/bin/gcloud /usr/local/bin/gcloud "$HOME/google-cloud-sdk/bin/gcloud"; do [[ -z "$GCLOUD" && -x "$p" ]] && GCLOUD="$p"; done
if [[ -z "$GCLOUD" ]]; then
  need_brew "the Google Cloud SDK"
  echo "  installing the Google Cloud SDK (a few minutes)..."
  brew install --cask google-cloud-sdk >/dev/null || fail "brew install --cask google-cloud-sdk"
  GCLOUD="$(command -v gcloud || true)"
  for p in /opt/homebrew/bin/gcloud /usr/local/bin/gcloud; do [[ -z "$GCLOUD" && -x "$p" ]] && GCLOUD="$p"; done
  [[ -n "$GCLOUD" ]] || fail "gcloud installed but not found on PATH; open a new terminal and re-run"
fi
ok "gcloud ($GCLOUD)"

step "2/6 Google login"
# print-access-token exits 0 with a dead token once session control has expired
# the login, so ask Google whether the token is valid (POST keeps it out of argv).
login_ok() {
  local t; t="$("$GCLOUD" auth print-access-token 2>/dev/null)" || return 1
  [[ -n "$t" ]] && curl -sf -o /dev/null --max-time 10 -X POST --data @- https://oauth2.googleapis.com/tokeninfo <<<"access_token=$t"
}
if login_ok; then
  ok "logged in as $("$GCLOUD" config get-value account 2>/dev/null)"
else
  echo "  a browser window opens: log in with your @codechum.com Google account"
  "$GCLOUD" auth login --brief >/dev/null 2>&1 || fail "gcloud auth login did not complete"
  ok "logged in as $("$GCLOUD" config get-value account 2>/dev/null)"
fi

step "3/6 tunnel to the team server ($API)"
if curl -sf --max-time 3 "$API/ready" >/dev/null 2>&1; then
  ok "already connected"
else
  GPY="$("$GCLOUD" info --format='value(basic.python_location)' 2>/dev/null || true)"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$GCLOUD</string>
    <string>compute</string><string>start-iap-tunnel</string>
    <string>$VM</string><string>63001</string>
    <string>--local-host-port=localhost:$PORT</string>
    <string>--zone=$ZONE</string><string>--project=$PROJECT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>CLOUDSDK_CORE_DISABLE_PROMPTS</key><string>1</string>
    <key>CLOUDSDK_PYTHON</key><string>${GPY:-/usr/bin/python3}</string>
  </dict>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || fail "launchctl could not load $PLIST"
  for _ in $(seq 1 20); do curl -sf --max-time 2 "$API/ready" >/dev/null 2>&1 && break; sleep 2; done
  if curl -sf --max-time 2 "$API/ready" >/dev/null 2>&1; then
    ok "connected (starts at login, restarts itself)"
  else
    tail -3 "$LOG" 2>/dev/null | sed 's/^/        /'
    fail "tunnel not up. Most likely an admin has not added you yet: ask them to run deploy-vm.sh add-user $("$GCLOUD" config get-value account 2>/dev/null), then re-run."
  fi
fi
# Connection check: every 5 minutes, a dialog with the fix whenever chum-mem is
# not connected (most often: Workspace session control expired the gcloud login,
# every 24 h). Copied out of the checkout so switching branches cannot remove it.
GPY="${GPY:-$("$GCLOUD" info --format='value(basic.python_location)' 2>/dev/null || true)}"
mkdir -p "$TOKEN_DIR" && chmod 700 "$TOKEN_DIR"
cp "$(cd "$(dirname "$0")" && pwd)/tunnel-auth-check.sh" "$AUTH_CHECK" || fail "could not copy tunnel-auth-check.sh to $AUTH_CHECK"
cat > "$AUTH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AUTH_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$AUTH_CHECK</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$AUTH_LABEL.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$AUTH_LABEL.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>CLOUDSDK_PYTHON</key><string>${GPY:-/usr/bin/python3}</string>
    <key>CHUM_GCLOUD</key><string>$GCLOUD</string>
    <key>CHUM_TUNNEL_LOG</key><string>$LOG</string>
    <key>CHUM_LOCAL_PORT</key><string>$PORT</string>
    <key>CHUM_TUNNEL_LABEL</key><string>$LABEL</string>
    <key>CHUM_REPO</key><string>$ROOT</string>
  </dict>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)" "$AUTH_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$AUTH_PLIST" || fail "launchctl could not load $AUTH_PLIST"
ok "connection check installed (a dialog offers the fix whenever chum-mem is not connected)"

step "4/6 your token"
check_token() { # $1 token -> HTTP code of an authenticated call
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @/dev/fd/9 9<<<"X-Chum-Token: $1" "$API/api/dashboard/summary"
}
save_token() { # $1 token, already accepted by the server
  ( umask 077; mkdir -p "$TOKEN_DIR"; printf '%s' "$1" > "$TOKEN_FILE" )
  chmod 700 "$TOKEN_DIR"; chmod 600 "$TOKEN_FILE"
}
ACCOUNT="$("$GCLOUD" config get-value account 2>/dev/null | tr 'A-Z' 'a-z')"
# Same naming as deploy-vm.sh add-user: juan.dc@codechum.com -> chum-mem-token-juan-dc-at-codechum-com
SECRET="chum-mem-token-$(printf '%s' "$ACCOUNT" | sed -e 's/@/-at-/' -e 's/[^a-z0-9-]/-/g')"
if [[ -n "${CHUM_TOKEN_FILE:-}" ]]; then
  T="$(tr -d '[:space:]' < "$CHUM_TOKEN_FILE" 2>/dev/null || true)"; SRC="$CHUM_TOKEN_FILE"
else
  T="$("$GCLOUD" secrets versions access latest --secret="$SECRET" --project="$PROJECT" 2>/dev/null | tr -d '[:space:]')"; SRC="Secret Manager ($SECRET)"
fi
if [[ -n "$T" ]]; then
  code="$(check_token "$T")"
  [[ "$code" == "200" ]] || { unset T; fail "the server rejected your token from $SRC (HTTP $code). Ask an admin to re-run: deploy-vm.sh add-user $ACCOUNT"; }
  save_token "$T"; unset T
  ok "your token for $ACCOUNT, from $SRC, saved to ~/.config/chum-mem/token (0600)"
elif [[ -s "$TOKEN_FILE" && "$(check_token "$(tr -d '[:space:]' < "$TOKEN_FILE")")" == "200" ]]; then
  ok "saved token works, but no personal token for $ACCOUNT yet: ask an admin to run deploy-vm.sh add-user $ACCOUNT, then re-run"
else
  fail "no token for $ACCOUNT. Ask an admin to run: deploy-vm.sh add-user $ACCOUNT  (then re-run this script)"
fi
LINE='export CHUM_MEMORY_API_TOKEN="$(cat "$HOME/.config/chum-mem/token" 2>/dev/null)"'
for rc in "$HOME/.zshenv" "$HOME/.bash_profile"; do
  [[ "$rc" == *bash_profile && "${SHELL:-}" != */bash ]] && continue
  grep -qF 'config/chum-mem/token' "$rc" 2>/dev/null || printf '\n# chum-mem team memory token (MCP server)\n%s\n' "$LINE" >> "$rc"
done
ok "MCP token export in ~/.zshenv"

step "5/6 identity"
if [[ "$ACCOUNT" == *@codechum.com || "$ACCOUNT" == *@gradechum.com ]]; then ok "memories are credited to $ACCOUNT"
else echo "  WARN  gcloud is logged in as '${ACCOUNT:-nobody}', not a company account: log in with your @codechum.com account (gcloud auth login) and re-run"; fi

step "6/6 check"
[[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/api/search" -X POST -H 'Content-Type: application/json' -d '{}')" == "401" ]] \
  && ok "server refuses requests without a token" || echo "  WARN  unexpected answer from the server without a token"
code="$(check_token "$(tr -d '[:space:]' < "$TOKEN_FILE")")"
[[ "$code" == "200" ]] || fail "authenticated call returned HTTP $code"
ok "authenticated call works"
printf '%s\n' "$SETUP_VERSION" > "$TOKEN_DIR/setup-version"

cat <<'EOF'

Done. Quit Claude Code and start it again from the monorepo root (the MCP
server reads the token at startup); approve the `chum-memory` MCP server if
asked. From then on your sessions are captured and matching repo docs are
attached to your prompts. Pause capture for a session with: CHUM_CAPTURE=0 claude
Held secrets: /chum-quarantine list
EOF
