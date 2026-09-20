#!/usr/bin/env bash
# Integration tests for scmn's docker handling using a mock `docker` CLI.
# Requires: bash, GNU screen, a temporary mock docker (test/mock-docker).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCMN="$HERE/../scmn"
MOCK="$HERE/mock-docker"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/dockerstate"
export MOCK_DOCKER_STATE="$STATE"
export MOCK_DOCKER_PID="$$"
export PATH="$HERE:$PATH"
export HOME="$TMP/home"
export SCREENDIR="$TMP/.screen"
export SCMN_STATE_DIR="$TMP/.state"
export SCMN_LOG="$TMP/scmn.log"
mkdir -p "$HOME" "$SCREENDIR" "$SCMN_STATE_DIR"
chmod 700 "$SCREENDIR"

cat > "$TMP/scmn.conf" <<EOF
# docker test services
foreground | - | docker run --name fg --label scmn.service=foreground img-fg:1 | none | - | no
autoname | - | docker run img-auto:1 | none | - | no
spin | - | docker run -d --name spinx --label scmn.service=spin img-spin:1 | none | - | always
detached | - | docker run -d --name detr --label scmn.service=detached img-det:1 | none | - | no
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
    "$SCMN" -c "$TMP/scmn.conf" "$@"
}

echo "== Start services =="
run_scmn start foreground >/dev/null 2>&1
run_scmn start autoname >/dev/null 2>&1
run_scmn start spin >/dev/null 2>&1
run_scmn start detached >/dev/null 2>&1

echo "== A: injection + single run each, no restart churn =="
sleep 2.6
assert_eq "$(grep -c '^run .*spinx' "$STATE/calls.log")" "1" "spin ran more than once (docker run loop present)"
assert_eq "$(grep -c '^run .*fg ' "$STATE/calls.log")" "1" "foreground ran more than once"
assert_eq "$(grep -c '^run ' "$STATE/calls.log")" "4" "total docker run calls"

grep -q '^run --name scmn_autoname --label scmn.service=autoname img-auto:1' "$STATE/calls.log" \
    && pass || fail "autoname did not get injected --name/--label"

echo "== H: start is idempotent for running containers =="
before=$(grep -c '^run .*detr' "$STATE/calls.log")
run_scmn start detached >/dev/null 2>&1
after=$(grep -c '^run .*detr' "$STATE/calls.log")
assert_eq "$before" "$after" "start restarted a running container"

echo "== I: reload does not restart healthy containers =="
before=$(grep -c '^run ' "$STATE/calls.log")
run_scmn reload >"$TMP/reload.log" 2>&1
after=$(grep -c '^run ' "$STATE/calls.log")
assert_eq "$before" "$after" "reload restarted running containers"
grep -q "already running" "$TMP/reload.log" && pass || fail "reload did not report already-running services"

echo "== C: status states / container stats =="
out=$(run_scmn status 2>&1)
assert_match "$(grep '^foreground' <<<"$out")" "RUNNING"
assert_match "$(grep '^autoname' <<<"$out")" "RUNNING"
assert_match "$(grep '^spin' <<<"$out")" "ORPHANED"
assert_match "$(grep '^detached' <<<"$out")" "ORPHANED"
fgline=$(grep '^foreground' <<<"$out")
assert_match "$fgline" "[0-9]+MB"

echo "== C2: detailed status page for docker services =="
dout=$(run_scmn status spin 2>&1)
assert_match "$(grep '^Container:' <<<"$dout")"     "pid [-0-9]+ +RAM - +up [0-9]{2}:[0-9]{2}:[0-9]{2}.*\(a[0-9]{11}\)"
assert_match "$(grep '^Workload proc:' <<<"$dout")" "RAM [0-9]+MB +up.*\\($(ps -o comm= -p $$ | xargs)\\)"
assert_match "$(grep 'Screen session:' <<<"$dout")" "not running"
assert_match "$dout" "Status: +ORPHANED"
fout=$(run_scmn status foreground 2>&1)
assert_match "$fout" "Status: +RUNNING"
assert_match "$(grep '^Screen session:' <<<"$fout")" "pid [0-9]+ +RAM [0-9]+MB +up.*(screen)"
assert_match "$(grep '^Container:' <<<"$fout")"      "pid [-0-9]+ +RAM - +up [0-9]{2}:[0-9]{2}:[0-9]{2}.*\(a[0-9]{11}\)"

echo "== D: check warnings =="
cout=$(run_scmn check 2>&1)
assert_match "$cout" "without '--name'"
assert_match "$cout" "auto_restart"
for s in foreground autoname spin detached; do
    assert_match "$cout" "Configuration check PASSED"
done

echo "== E: stop an orphaned docker service (dead screen, live container) =="
run_scmn stop spin >/dev/null 2>&1
assert_eq "$(docker ps -a --format '{{.Names}}' | grep -x spinx || true)" "" "spinx container still exists"
sout=$(run_scmn status 2>&1)
assert_match "$(grep '^spin' <<<"$sout")" "STOPPED"

echo "== F: orphans scan (ORPHANED + UNTRACKED) =="
docker run -d --name unrelated img-x:1 >/dev/null 2>&1
oout=$(run_scmn docker orphans 2>&1)
assert_match "$(grep -i untracked <<<"$oout")" "UNTRACKED"
assert_match "$(grep -i 'detr ' <<<"$oout")" "ORPHANED"

echo "== G: orphans --clean (untracked is safe) =="
gout=$(printf 'n\n' | run_scmn docker orphans --clean 2>&1)
assert_eq "$(docker ps -a --format '{{.Names}}' | grep -x detr || true)" "" "orphan detr not cleaned"
assert_eq "$(docker ps -a --format '{{.Names}}' | grep -x unrelated || true)" "unrelated" "untracked container was removed"
assert_eq "$(docker ps -a --format '{{.Names}}' | grep -x fg || true)" "fg" "managed container was removed"

echo
echo "PASSED: $PASSES, FAILED: $FAILURES"
[[ $FAILURES -eq 0 ]]