#!/usr/bin/env bash
# Core flow integration tests for scmn (non-docker): start/stop/restart/reload,
# enable/disable, and the shortname suffix-collision regression.
# Requires: bash, GNU screen.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCMN="$HERE/../scmn"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export SCREENDIR="$TMP/.screen"
export SCMN_STATE_DIR="$TMP/.state"
export SCMN_LOG="$TMP/scmn.log"
mkdir -p "$HOME" "$SCREENDIR" "$SCMN_STATE_DIR"
chmod 700 "$SCREENDIR"

CONF="$TMP/scmn.conf"
cat > "$CONF" <<EOF
# core test services
bshell | - | sleep 120 | none | - | always
bbshell | - | sleep 120 | none | - | always
EOF

FAILURES=0
PASSES=0

pass() { PASSES=$((PASSES + 1)); }
fail() { FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass; else fail "'$1' != '$2' ($3)"; fi
}
assert_match() {
    if grep -qE "$2" <<<"$1"; then pass; else fail "pattern '$2' missing in: $(head -c 400 <<<"$1")"; fi
}
assert_not_match() {
    if grep -qE "$2" <<<"$1"; then fail "unexpected pattern '$2' in: $(head -c 400 <<<"$1")"; else pass; fi
}

run_scmn() {
    "$SCMN" -c "$CONF" "$@"
}

echo "== Start services =="
run_scmn start bshell >/dev/null 2>&1
run_scmn start bbshell >/dev/null 2>&1
sleep 1

echo "== A: both running with distinct pids =="
out=$(run_scmn status 2>&1)
bs_line=$(grep '^bshell ' <<<"$out")
bbs_line=$(grep '^bbshell ' <<<"$out")
assert_match "$bs_line" "RUNNING"
assert_match "$bbs_line" "RUNNING"
nthree=$(grep -c '^b*shell.*RUNNING' <<<"$out")
assert_eq "$nthree" "2" "expected both services RUNNING"

echo "== A2: PID column shows the leaf workload process, not the bash wrapper =="
leaf_of() {
    local pid="${1%%.*}"
    local child
    while child=$(pgrep -P "$pid" 2>/dev/null | head -n 1); [[ -n "$child" ]]; do
        pid="$child"
    done
    echo "$pid"
}
bs_screen=$(SCREENDIR="$TMP/.screen" screen -ls 2>/dev/null | grep -oE '[0-9]+\.bshell\b' | head -n 1)
bs_expected=$(leaf_of "$bs_screen")
bs_shown=$(awk '{print $3}' <<<"$bs_line")
assert_eq "$bs_shown" "$bs_expected" "status PID is not the leaf process (got bash wrapper?)"
assert_match "$bs_line" "[0-9]+MB"

echo "== B: stop 'bshell' must not touch 'bbshell' (suffix collision) =="
run_scmn stop bshell >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^bbshell ' <<<"$out")" "RUNNING"
assert_match "$(grep '^bshell ' <<<"$out")" "STOPPED"

echo "== C: restart 'bshell' leaves 'bbshell' alone =="
run_scmn restart bshell >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^bshell ' <<<"$out")" "RUNNING"
assert_match "$(grep '^bbshell ' <<<"$out")" "RUNNING"
assert_not_match "$(grep '^bbshell ' <<<"$out")" "STOPPED"

echo "== D: reload starts new services, restarts changed, leaves untouched =="
bs_pid_before=$(grep '^bshell ' <<<"$(run_scmn status 2>&1)" | awk '{print $3}')
bbs_pid_before=$(grep '^bbshell ' <<<"$(run_scmn status 2>&1)" | awk '{print $3}')
cat > "$CONF" <<EOF
# core test services (reloaded)
bshell | - | sleep 120 | $TMP/bshell.log | - | always
bbshell | - | sleep 120 | none | - | always
core_new | - | sleep 120 | none | - | always
EOF
run_scmn reload >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^core_new ' <<<"$out")" "RUNNING"
assert_match "$(grep '^bshell ' <<<"$out")" "RUNNING"
assert_match "$(grep '^bbshell ' <<<"$out")" "RUNNING"
bs_pid_after=$(grep '^bshell ' <<<"$out" | awk '{print $3}')
bbs_pid_after=$(grep '^bbshell ' <<<"$out" | awk '{print $3}')
assert_not_match "$bs_pid_before" "^${bs_pid_after}\$" "changed service should have been restarted"
assert_match "$bbs_pid_after" "^${bbs_pid_before}\$" "untouched service should keep its pid"

echo "== E: enable/disable round-trip and --now =="
run_scmn disable core_new >/dev/null 2>&1
assert_match "$(run_scmn check 2>&1)" "1 disabled"
run_scmn enable core_new --now >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^core_new ' <<<"$out")" "RUNNING"
run_scmn disable core_new --now >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^core_new ' <<<"$out")" "DISABLED"
nbackt=$(grep '^# core_new ' "$CONF")
assert_not_match "$nbackt" "sha" "core_new should be commented out"

echo "== G: detailed status page for a running service =="
out=$(run_scmn status bshell 2>&1)
assert_match "$out" "Service: +bshell$"
assert_match "$out" "Status: +RUNNING"
assert_match "$out" "Auto-restart: +always"
bs_sess=$(SCREENDIR="$TMP/.screen" screen -ls 2>/dev/null | grep -oE '[0-9]+\.bshell\b' | head -n 1)
bs_sess="${bs_sess%%.*}"
assert_match "$(grep '^Screen session:' <<<"$out")" "pid ${bs_sess} +RAM [0-9]+MB +up .*\(screen\)"
assert_match "$(grep '^Workload proc:' <<<"$out")" "pid [0-9]+ +RAM [0-9]+MB +up .*\(sleep\)"

echo "== F: stop 'bbshell' ends cleanly =="
run_scmn stop bbshell >/dev/null 2>&1
run_scmn stop bshell >/dev/null 2>&1
sleep 0.6
out=$(run_scmn status 2>&1)
assert_match "$(grep '^bbshell ' <<<"$out")" "STOPPED"
assert_match "$(grep '^bshell ' <<<"$out")" "STOPPED"

echo "== F2: detail page for a stopped service =="
out=$(run_scmn status bbshell 2>&1)
assert_match "$out" "Status: +STOPPED"
assert_match "$(grep 'Screen session:' <<<"$out")" "not running"
assert_match "$(grep 'Workload proc:' <<<"$out")" "not running"

echo "== K: start works from a cron-like minimal env (no ~/.local/bin in PATH) =="
CRON_HOME="$TMP/cronhome"
CRON_SCREEN="$TMP/.screen-cron"
CRON_STATE="$TMP/.state-cron"
CRON_LOG="$TMP/scmn-cron.log"
mkdir -p "$CRON_HOME" "$CRON_HOME/.local/bin" "$CRON_SCREEN" "$CRON_STATE"
chmod 700 "$CRON_SCREEN"
cat > "$CRON_HOME/.local/bin/bitbang" <<'EOF'
#!/usr/bin/env bash
exec tail -f /dev/null
EOF
chmod +x "$CRON_HOME/.local/bin/bitbang"
cat > "$TMP/cron.conf" <<EOF
bbstub | - | bitbang serve shell | none | - | never
EOF

run_cron_scmn() {
    env -i HOME="$CRON_HOME" SCREENDIR="$CRON_SCREEN" SCMN_STATE_DIR="$CRON_STATE" \
        SCMN_LOG="$CRON_LOG" PATH="/usr/bin:/bin" \
        "$SCMN" -c "$TMP/cron.conf" "$@"
}

run_cron_scmn start bbstub >/dev/null 2>&1
sleep 0.6
kout=$(run_cron_scmn status bbstub 2>&1)
assert_match "$kout" "Status: +RUNNING"
assert_match "$(SCREENDIR="$CRON_SCREEN" screen -ls 2>/dev/null)" "\.bbstub\b"

echo "== K2: missing binary -> clear error, no RESTARTING loop =="
cat > "$TMP/cron.conf" <<EOF
nosuchbin | - | nosuchbinary_xyz | none | - | always
EOF
k2out=$(run_cron_scmn start nosuchbin 2>&1 || true)
assert_match "$k2out" "Command not found on PATH: 'nosuchbinary_xyz'"
assert_eq "$(SCREENDIR="$CRON_SCREEN" screen -ls 2>/dev/null | grep -c '\.nosuchbin\b' || true)" "0" "screen session created for missing binary"
assert_match "$(run_cron_scmn status nosuchbin 2>&1)" "Status: +STOPPED"

echo
echo "PASSED: $PASSES, FAILED: $FAILURES"
[[ $FAILURES -eq 0 ]]