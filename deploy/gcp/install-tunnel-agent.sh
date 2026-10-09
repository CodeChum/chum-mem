#!/usr/bin/env bash
# install-tunnel-agent.sh — one-time, per engineer (macOS). Registers a launchd
# agent that keeps `gcloud compute start-iap-tunnel` running so the chum-memory
# plugin always finds the team server at http://localhost:63001.
#
# Usage: deploy/gcp/install-tunnel-agent.sh [install|uninstall|status|token [TOKEN]]
set -euo pipefail
PROJECT="${CHUM_GCP_PROJECT:-gradechum}"
ZONE="${CHUM_GCP_ZONE:-asia-east1-b}"
VM="${CHUM_GCP_VM:-gradechum-chum-mem}"
PORT="${CHUM_LOCAL_PORT:-63001}"
LABEL="com.codechum.chum-mem-tunnel"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/chum-mem-tunnel.log"
GCLOUD="$(command -v gcloud || true)"

case "${1:-install}" in
  install)
    [[ -n "$GCLOUD" ]] || { echo "gcloud not found; install the Google Cloud SDK and run 'gcloud auth login' first" >&2; exit 1; }
    "$GCLOUD" auth print-access-token >/dev/null 2>&1 || { echo "run 'gcloud auth login' (your @codechum.com account) first" >&2; exit 1; }
    mkdir -p "$(dirname "$PLIST")"
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
  </dict>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    for i in $(seq 1 15); do curl -sf --max-time 2 "http://localhost:$PORT/ready" >/dev/null 2>&1 && break; sleep 2; done
    if curl -sf --max-time 2 "http://localhost:$PORT/ready" >/dev/null 2>&1; then
      echo "tunnel agent installed and connected: http://localhost:$PORT -> $VM"
    else
      echo "agent installed but the tunnel is not up yet; check $LOG (needs IAP-secured Tunnel User on project $PROJECT)" >&2; exit 1
    fi
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"; echo "tunnel agent removed"
    ;;
  token)
    # Store the team API token for the hooks (file) and for the MCP server (env
    # var exported from ~/.zshenv). Paste it when prompted; it is never echoed.
    mkdir -p "$HOME/.config/chum-mem"; chmod 700 "$HOME/.config/chum-mem"
    if [[ -n "${2:-}" ]]; then printf '%s' "$2" > "$HOME/.config/chum-mem/token"
    else read -r -s -p "chum-mem API token: " T; echo; printf '%s' "$T" > "$HOME/.config/chum-mem/token"; fi
    chmod 600 "$HOME/.config/chum-mem/token"
    LINE='export CHUM_MEMORY_API_TOKEN="$(cat "$HOME/.config/chum-mem/token" 2>/dev/null)"'
    grep -qF 'config/chum-mem/token' "$HOME/.zshenv" 2>/dev/null || printf '\n# chum-mem team memory token (hooks + MCP)\n%s\n' "$LINE" >> "$HOME/.zshenv"
    echo "token saved to ~/.config/chum-mem/token (0600) and exported from ~/.zshenv; open a new terminal before starting Claude Code"
    ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E 'state|pid' | head -2 || echo "not installed"
    curl -s --max-time 2 "http://localhost:$PORT/ready" | head -c 120; echo
    ;;
  *) echo "usage: $0 [install|uninstall|status|token [TOKEN]]"; exit 2 ;;
esac
