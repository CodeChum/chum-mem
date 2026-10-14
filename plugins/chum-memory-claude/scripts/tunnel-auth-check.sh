#!/bin/bash
# tunnel-auth-check.sh — when chum-mem is not connected, tell the engineer in a
# macOS dialog and offer the fix. Runs every 5 minutes under launchd (setup-
# engineer.sh copies it to ~/.config/chum-mem/ and installs
# com.codechum.chum-mem-auth-check), and in the background from the hook whenever
# chum-mem is unreachable, so an engineer who never ran setup is asked too.
#
#   gcloud not signed in, or login expired (IAP 4033)  -> [Sign in]: browser login.
#     Workspace Cloud session control expires it every 24 h; the tunnel loads
#     credentials per connection, so it recovers without a restart.
#   VM or firewall down (IAP 4003)                      -> told; only the admin can fix it
#   CHUM_DIALOG_REASON=update (from the hook: the pulled setup-engineer.sh is a
#   newer SETUP_VERSION than this Mac ran)              -> [Update]: same as Set up
#   anything else: not set up, tunnel agent missing,
#   token missing or rejected, unexplained failure      -> [Set up]: Terminal runs
#     setup-engineer.sh, which repairs whatever step is missing
# No internet: no dialog. "Later", or no answer in 15 minutes, snoozes for an hour.
# One dialog at a time across the launchd job and every session's hook.
#
# Env: CHUM_REPO (monorepo root, for Set up), CHUM_LOCAL_PORT, CHUM_TUNNEL_LOG,
#      CHUM_TUNNEL_LABEL, CHUM_GCLOUD, CHUM_DIALOG_REASON, CHUM_ONLINE_URL (tests)
set -u
PORT="${CHUM_LOCAL_PORT:-63001}"
API="http://localhost:$PORT"
REPO="${CHUM_REPO:-}"
TUNNEL_LABEL="${CHUM_TUNNEL_LABEL:-com.codechum.chum-mem-tunnel}"
CONF="$HOME/.config/chum-mem"
SNOOZE="$CONF/.dialog-snooze"
LOCK="$CONF/.dialog-lock"
GCLOUD="${CHUM_GCLOUD:-$(command -v gcloud || true)}"
for p in /opt/homebrew/bin/gcloud /usr/local/bin/gcloud "$HOME/google-cloud-sdk/bin/gcloud"; do
  [[ -z "$GCLOUD" && -x "$p" ]] && GCLOUD="$p"
done
LOG="${CHUM_TUNNEL_LOG:-}"
if [[ -z "$LOG" ]]; then  # setup-engineer.sh and install-tunnel-agent.sh log to different files
  for f in "$HOME/Library/Logs/com.codechum.chum-mem-tunnel.log" "$HOME/Library/Logs/chum-mem-tunnel.log"; do
    [[ -f "$f" ]] && { [[ -z "$LOG" || "$f" -nt "$LOG" ]] && LOG="$f"; }
  done
fi

[[ -n "$(find "$SNOOZE" -mmin -60 2>/dev/null)" ]] && exit 0
mkdir -p "$CONF" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]] || exit 0  # a dialog is open
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0         # stale: its run died
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

token_rejected() {
  local t code
  t="$(tr -d '[:space:]' 2>/dev/null < "$CONF/token")"
  [[ -n "$t" ]] || return 0
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H @/dev/fd/9 9<<<"X-Chum-Token: $t" "$API/api/dashboard/summary")"
  [[ "$code" == "401" ]]
}
CFG="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
ACCOUNT="$(sed -n 's/^account *= *//p' "$CFG/configurations/config_$(cat "$CFG/active_config" 2>/dev/null || echo default)" 2>/dev/null | head -1)"

if [[ "${CHUM_DIALOG_REASON:-}" == "update" ]]; then
  CAUSE=update
elif curl -sf --max-time 10 "$API/health" >/dev/null 2>&1; then
  token_rejected || { rm -f "$SNOOZE"; exit 0; }
  CAUSE=setup
elif [[ -z "$GCLOUD" || ! -f "$HOME/Library/LaunchAgents/$TUNNEL_LABEL.plist" ]]; then
  CAUSE=setup
elif [[ -z "$ACCOUNT" ]]; then
  CAUSE=signin
elif ! curl -s -o /dev/null --max-time 5 "${CHUM_ONLINE_URL:-https://www.gstatic.com/generate_204}"; then
  exit 0  # offline: nothing the engineer can fix
else
  sleep 1  # the failed /health above is what makes the tunnel log its IAP error
  CAUSE=setup
  if [[ -n "$LOG" && -n "$(find "$LOG" -mmin -10 2>/dev/null)" ]]; then
    case "$(tail -n 60 "$LOG" 2>/dev/null | grep -oE '\[40(03|33):|invalid_grant|[Rr]eauthentication|active account' | tail -1)" in
      "[4033:"|invalid_grant|[Rr]eauthentication|"active account") CAUSE=signin ;;
      "[4003:") CAUSE=server ;;
    esac
  fi
  # An unexplained failure is often a VM redeploy restarting the API: only
  # ask when it is still failing a little later.
  if [[ "$CAUSE" == setup ]]; then
    sleep "${CHUM_RETRY_SECS:-20}"
    curl -sf --max-time 10 "$API/health" >/dev/null 2>&1 && exit 0
  fi
fi

ask() {  # $1 message, $2 action button -> prints the button pressed ("" on timeout)
  osascript - "$1" "$2" <<'EOF' 2>/dev/null
on run argv
  display dialog (item 1 of argv) with title "chum-mem" buttons {"Later", item 2 of argv} default button 2 with icon caution giving up after 900
  return button returned of result
end run
EOF
}
notify() { osascript - "$1" <<'EOF' >/dev/null 2>&1
on run argv
  display notification (item 1 of argv) with title "chum-mem"
end run
EOF
}
snooze() { : > "$SNOOZE"; }

case "$CAUSE" in
  signin)
    [[ "$(ask "Your Google Cloud sign-in has expired, so team memory (chum-mem) is disconnected.

Sign in again as ${ACCOUNT:-your @codechum.com account}? A browser window opens." "Sign in")" == "Sign in" ]] || { snooze; exit 0; }
    # gcloud waits for the browser callback forever; give up after 10 minutes.
    # With an account named, gcloud reuses its stored (expired) credentials
    # and opens no browser unless --force is given.
    "$GCLOUD" auth login ${ACCOUNT:+"$ACCOUNT" --force} --brief >/dev/null 2>&1 &
    LOGIN_PID=$!
    for _ in $(seq 1 600); do kill -0 "$LOGIN_PID" 2>/dev/null || break; sleep 1; done
    kill "$LOGIN_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
      curl -sf --max-time 5 "$API/health" >/dev/null 2>&1 && { notify "Signed in. Team memory is connected again."; exit 0; }
      sleep 3
    done
    notify "Sign-in did not complete. You will be asked again in 5 minutes."
    ;;
  server)
    ask "The chum-mem team server cannot be reached (IAP error 4003: its firewall rule is missing or the VM is down).

This cannot be fixed from your Mac: tell the chum-mem admin. Your sessions are queued and sync once it is back." "OK" >/dev/null
    snooze
    ;;
  setup|update)
    SETUP="$REPO/.claude/chum-mem/scripts/setup-engineer.sh"
    if [[ -z "$REPO" || ! -f "$SETUP" ]]; then
      ask "Team memory (chum-mem) is not connected.

To fix it, run this in Claude Code at the gradechum monorepo root:
! bash .claude/chum-mem/scripts/setup-engineer.sh" "OK" >/dev/null
      snooze; exit 0
    fi
    if [[ "$CAUSE" == "update" ]]; then
      BTN="Update"; MSG="A chum-mem update is available for this Mac.

Install it now? A Terminal window opens and re-runs the chum-mem setup; it keeps what already works and only changes what is new."
    else
      BTN="Set up"; MSG="Team memory (chum-mem) is not connected on this Mac.

Run the chum-mem setup now? A Terminal window opens; it repairs whatever is missing and may open a browser to sign in."
    fi
    [[ "$(ask "$MSG" "$BTN")" == "$BTN" ]] || { snooze; exit 0; }
    printf '#!/bin/bash\ncd %q && bash .claude/chum-mem/scripts/setup-engineer.sh\necho; read -r -p "Press Return to close. " _\n' "$REPO" > "$CONF/setup.command"
    chmod 700 "$CONF/setup.command"
    open "$CONF/setup.command"
    touch -t "$(date -v-45M +%Y%m%d%H%M)" "$SNOOZE"  # give setup 15 minutes before asking again
    ;;
esac
exit 0
