#!/bin/bash
# windows-setup-test.sh — runs setup-engineer.sh for real on Windows (Git Bash),
# with a fake gcloud.cmd whose `start-iap-tunnel` serves tests/fake-api.py on the
# local port. Checks the Startup shortcut, the PowerShell tunnel loop (restart,
# one instance), the token check, the MCP user env var, and a hook that then
# captures through the tunnel with the token. CI only: it writes the runner's
# Startup folder path override, ~/.config/chum-mem and a user env var.
set -u
[[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] || { echo "Windows (Git Bash) only"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chum-win-setup.XXXXXX")"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
ps() { powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r'; }
stop_tunnel() {  # the loop and its fake tunnel
  ps 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*tunnel.ps1*" -or $_.CommandLine -like "*fake-api.py*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null
}
trap stop_tunnel EXIT

PORT=$(( 40000 + RANDOM % 20000 ))
TOKEN="win-setup-token-$RANDOM$RANDOM"
STATE="$TMP/state"; mkdir -p "$STATE" "$TMP/startup" "$TMP/gc"
# Fake gcloud: a .cmd (what setup calls on Windows) that runs fake-gcloud.sh in Git Bash.
BASH_EXE="$(cygpath -w "$(command -v bash)")"
cat > "$TMP/gc/fake-gcloud.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/gcloud-calls.log"
case "\$1 \$2" in
  "auth print-access-token") echo not-a-real-token ;;
  "auth login") exit 0 ;;
  "config get-value") echo rey.test@codechum.com ;;
  "secrets versions") printf '%s\r\n' "$TOKEN" ;;
  "compute start-iap-tunnel")
    echo "Listening on port [$PORT]." >&2
    exec python "$HERE/fake-api.py" "$PORT" "$STATE" ;;
  *) exit 1 ;;
esac
EOF
printf '@"%s" "%s" %%*\r\n' "$BASH_EXE" "$(cygpath -w "$TMP/gc/fake-gcloud.sh")" > "$TMP/gc/gcloud.cmd"

REPO="$TMP/monorepo"; mkdir -p "$REPO/.claude/chum-mem"
git -C "$REPO" init -q && cp -r "$SCRIPTS" "$REPO/.claude/chum-mem/scripts"
printf '{"projectId":"cbcbcbcb-0000-4000-8000-0000000000ee","name":"t"}\n' > "$REPO/.chum-mem"
CONF="$HOME/.config/chum-mem"

echo "setup"
out=$(cd "$REPO" && CHUM_GCLOUD="$TMP/gc/gcloud.cmd" CHUM_LOCAL_PORT="$PORT" CHUM_STARTUP_DIR="$TMP/startup" \
  bash .claude/chum-mem/scripts/setup-engineer.sh 2>&1); rc=$?
echo "$out" | sed 's/^/    | /'
check "setup exits 0" '[[ $rc -eq 0 ]]'
check "the tunnel loop came up (connected)" 'grep -q "ok    connected" <<<"$out"'
check "the tunnel was started with the VM, port and project" \
  'grep -q "compute start-iap-tunnel gradechum-chum-mem 63001 --local-host-port=localhost:$PORT --zone=asia-east1-b --project=gradechum" "$TMP/gcloud-calls.log"'
check "the token secret is named after the account" 'grep -q "secret=chum-mem-token-rey-test-at-codechum-com" "$TMP/gcloud-calls.log"'
check "token saved without the CR from gcloud.cmd" '[[ "$(cat "$CONF/token")" == "$TOKEN" ]]'
check "the server saw the token (check_token through curl -K -)" 'grep -qxF "$TOKEN" "$STATE/tokens.log"'
check "the token is in no gcloud call" '! grep -qF "$TOKEN" "$TMP/gcloud-calls.log"'
lnk="$(cygpath -w "$TMP/startup/chum-mem tunnel.lnk")"
check "Startup shortcut created" '[[ -f "$TMP/startup/chum-mem tunnel.lnk" ]]'
args=$(ps "(New-Object -ComObject WScript.Shell).CreateShortcut('$lnk').Arguments")
check "the shortcut runs tunnel.ps1 hidden ($args)" '[[ "$args" == *"-WindowStyle Hidden"*"tunnel.ps1"* ]]'
envtok=$(ps "[Environment]::GetEnvironmentVariable('CHUM_MEMORY_API_TOKEN','User')")
check "MCP token set as a user environment variable" '[[ "$envtok" == "$TOKEN" ]]'
check "setup-version recorded" '[[ -s "$CONF/setup-version" ]]'

echo "tunnel loop"
n_loops() {  # not counting this query's own PowerShell, whose command line names tunnel.ps1 too
  ps '@(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq "powershell.exe" -and $_.CommandLine -like "*-File*tunnel.ps1*" }).Count'
}
ps "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"$(cygpath -w "$CONF/tunnel.ps1")\"'" >/dev/null
sleep 5
check "a second loop exits at once (one tunnel per user): $(n_loops) running" '[[ "$(n_loops)" == 1 ]]'
ps 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*fake-api.py*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }' >/dev/null
sleep 2
check "tunnel killed -> /ready fails" '! curl -sf --max-time 2 "http://localhost:$PORT/ready" >/dev/null'
for _ in $(seq 1 20); do curl -sf --max-time 2 "http://localhost:$PORT/ready" >/dev/null && break; sleep 1; done
check "the loop restarts the tunnel" 'curl -sf --max-time 2 "http://localhost:$PORT/ready" >/dev/null'

echo "hook through the tunnel"
: > "$STATE/tokens.log"; : > "$STATE/requests.log"
for ev in SessionStart UserPromptSubmit Stop; do
  jq -cn --arg ev "$ev" --arg r "$REPO" '{session_id:"win-1", hook_event_name:$ev, cwd:$r, source:"startup", prompt:"where is the export queue?", last_assistant_message:"done"}' \
    | CHUM_MEMORY_API_URL="http://localhost:$PORT" CLAUDE_PROJECT_DIR="$REPO" bash "$REPO/.claude/chum-mem/scripts/hook-dispatch.sh" > "$TMP/hook-$ev.out" 2>&1
done
check "hooks sent the token from ~/.config/chum-mem/token" 'grep -qxF "$TOKEN" "$STATE/tokens.log"'
check "the session's events were captured" 'grep -q "^POST /v1/ingest/session/event" "$STATE/requests.log"'
check "no API-unreachable notice" '! grep -q "unreachable" "$TMP"/hook-*.out'
check "the token header file is beside the token" '[[ "$(cat "$CONF/token.header")" == "X-Chum-Token: $TOKEN" ]]'

echo "re-run"
out=$(cd "$REPO" && CHUM_GCLOUD="$TMP/gc/gcloud.cmd" CHUM_LOCAL_PORT="$PORT" CHUM_STARTUP_DIR="$TMP/startup" \
  bash .claude/chum-mem/scripts/setup-engineer.sh 2>&1); rc=$?
check "re-running setup is safe (already connected)" '[[ $rc -eq 0 ]] && grep -q "already connected" <<<"$out"'

ps "[Environment]::SetEnvironmentVariable('CHUM_MEMORY_API_TOKEN', \$null, 'User')" >/dev/null
echo "passed $PASS, failed $FAIL  (scratch: $TMP)"
[[ "$FAIL" -eq 0 ]]
