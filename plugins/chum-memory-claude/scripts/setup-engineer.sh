#!/usr/bin/env bash
# setup-engineer.sh — one-command chum-mem setup for a GradeChum engineer (macOS).
#
# Run it from a Claude Code session in the monorepo, with the team token copied
# to the clipboard (from the password manager or the admin's DM):
#
#   ! bash .claude/chum-mem/scripts/setup-engineer.sh
#
# The token is read from the clipboard, checked against the server, saved to
# ~/.config/chum-mem/token (0600) and then cleared from the clipboard. It is
# never printed and never typed into the Claude prompt (prompts are captured).
#
# Steps, each skipped when already done: jq + Google Cloud SDK (Homebrew),
# `gcloud auth login` (browser), the launchd IAP tunnel agent on
# localhost:63001, the token, the MCP env var in ~/.zshenv, git user.email.
# Safe to re-run. Prerequisite from an admin: the IAP-secured Tunnel User role
# on project gradechum.
#
# Env: CHUM_TOKEN_FILE=<path>  read the token from a file instead of the clipboard
#      CHUM_SETUP_LABEL / CHUM_LOCAL_PORT  launchd label / local port (tests)
set -uo pipefail
PROJECT="${CHUM_GCP_PROJECT:-gradechum}"
ZONE="${CHUM_GCP_ZONE:-asia-east1-b}"
VM="${CHUM_GCP_VM:-gradechum-chum-mem}"
PORT="${CHUM_LOCAL_PORT:-63001}"
LABEL="${CHUM_SETUP_LABEL:-com.codechum.chum-mem-tunnel}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/$LABEL.log"
TOKEN_DIR="$HOME/.config/chum-mem"
TOKEN_FILE="$TOKEN_DIR/token"
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
if "$GCLOUD" auth print-access-token >/dev/null 2>&1; then
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
    fail "tunnel not up. Most likely you lack the IAP-secured Tunnel User role on project $PROJECT: ask an admin, then re-run."
  fi
fi

step "4/6 team token"
check_token() { # $1 token -> HTTP code of an authenticated call
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @/dev/fd/9 9<<<"X-Chum-Token: $1" "$API/api/dashboard/summary"
}
if [[ -s "$TOKEN_FILE" && "$(check_token "$(tr -d '[:space:]' < "$TOKEN_FILE")")" == "200" ]]; then
  ok "saved token works"
else
  if [[ -n "${CHUM_TOKEN_FILE:-}" ]]; then T="$(tr -d '[:space:]' < "$CHUM_TOKEN_FILE" 2>/dev/null || true)"; SRC="$CHUM_TOKEN_FILE"
  else T="$(pbpaste 2>/dev/null | tr -d '[:space:]')"; SRC="the clipboard"; fi
  [[ -n "$T" ]] || fail "no token in $SRC. Copy the team token (ask an admin), then re-run. Do not paste it into the Claude prompt."
  [[ "${#T}" -ge 20 && "${#T}" -le 200 && "$T" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail "$SRC does not hold a token (wrong length or characters). Copy the team token and re-run."
  code="$(check_token "$T")"
  [[ "$code" == "200" ]] || { unset T; fail "the server rejected the token from $SRC (HTTP $code). Check you copied the whole team token."; }
  ( umask 077; mkdir -p "$TOKEN_DIR"; printf '%s' "$T" > "$TOKEN_FILE" )
  chmod 700 "$TOKEN_DIR"; chmod 600 "$TOKEN_FILE"
  unset T
  if [[ -z "${CHUM_TOKEN_FILE:-}" ]]; then printf '' | pbcopy; ok "token accepted and saved to ~/.config/chum-mem/token (0600); clipboard cleared"
  else ok "token accepted and saved to ~/.config/chum-mem/token (0600)"; fi
fi
LINE='export CHUM_MEMORY_API_TOKEN="$(cat "$HOME/.config/chum-mem/token" 2>/dev/null)"'
for rc in "$HOME/.zshenv" "$HOME/.bash_profile"; do
  [[ "$rc" == *bash_profile && "${SHELL:-}" != */bash ]] && continue
  grep -qF 'config/chum-mem/token' "$rc" 2>/dev/null || printf '\n# chum-mem team memory token (MCP server)\n%s\n' "$LINE" >> "$rc"
done
ok "MCP token export in ~/.zshenv"

step "5/6 identity"
EMAIL="$(git -C "$ROOT" config user.email || true)"
if [[ "$EMAIL" == *@codechum.com || "$EMAIL" == *@gradechum.com ]]; then ok "memories are attributed to $EMAIL"
else echo "  WARN  git user.email is '${EMAIL:-unset}'; memories are attributed to it. Set it: git config --global user.email you@codechum.com"; fi

step "6/6 check"
[[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/api/search" -X POST -H 'Content-Type: application/json' -d '{}')" == "401" ]] \
  && ok "server refuses requests without a token" || echo "  WARN  unexpected answer from the server without a token"
code="$(check_token "$(tr -d '[:space:]' < "$TOKEN_FILE")")"
[[ "$code" == "200" ]] || fail "authenticated call returned HTTP $code"
ok "authenticated call works"

cat <<'EOF'

Done. Quit Claude Code and start it again from the monorepo root (the MCP
server reads the token at startup); approve the `chum-memory` MCP server if
asked. From then on your sessions are captured and matching repo docs are
attached to your prompts. Pause capture for a session with: CHUM_CAPTURE=0 claude
Held secrets: /chum-quarantine list
EOF
