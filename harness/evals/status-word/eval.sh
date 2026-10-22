#!/usr/bin/env bash
# status-word: the close-path status readers read the status word right after "**Overall status:** ",
# never anywhere in the line, and accept em dash, en dash and hyphen.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
# The three readers, taken from the files as they stand: both drivers' latest_status, and evidence-gate.py's.
eval "wo_$(sed -n '/^latest_status() {/,/^}/p' "$PIPELINE_ROOT/bin/wo")"
eval "bug_$(sed -n '/^latest_status() {/,/^}/p' "$PIPELINE_ROOT/bin/bug")"
type wo_latest_status >/dev/null 2>&1 && type bug_latest_status >/dev/null 2>&1 || { echo "FAIL setup: could not read latest_status from the drivers"; exit 1; }
py_status() { python3 -I -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("eg",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.latest_status(sys.argv[2]))' "$PIPELINE_ROOT/core/hooks/evidence-gate.py" "$1"; }
n=0
expect() { # <id> <expected> <status line>: every reader reads the line as expected
  n=$((n+1)); f="$EVAL_TMP/v$n.md"; printf '# V\n\n%s\n\n### Run\n\n- **Status:** EXECUTED — PASS\n' "$3" > "$f"
  for r in wo bug py; do
    case "$r" in wo) got="$(wo_latest_status "$f")";; bug) got="$(bug_latest_status "$f")";; py) got="$(py_status "$f")";; esac
    [ "$got" = "$2" ] || { echo "FAIL $1: $r reads '$3' as $got, not $2"; exit 1; }
  done; }
# S1: a failing run whose suite path holds the words of a pass reads as FAIL
expect S1 FAIL '**Overall status:** EXECUTED — FAIL (last run 1, tree t, suite s/EXECUTED — PASS.sh@abc, checks 0/3)'
# S2: a passing run whose suite path holds RUNNING reads as PASS, not RUNNING
expect S2 PASS '**Overall status:** EXECUTED — PASS (last run 1, tree t, suite s/RUNNING.sh@abc, checks 3/3)'
# S3: a failing run whose suite path holds NOT EXECUTED reads as FAIL
expect S3 FAIL '**Overall status:** EXECUTED - FAIL (last run 1, tree t, suite s/NOT EXECUTED.sh@abc)'
expect S3 none '**Overall status:** something else (suite s/NOT EXECUTED.sh@abc)'
# S4: em dash, en dash and hyphen all read
expect S4 PASS '**Overall status:** EXECUTED — PASS'
expect S4 PASS '**Overall status:** EXECUTED – PASS (last run 1)'
expect S4 PASS '**Overall status:** EXECUTED - PASS (last run 1)'
expect S4 FAIL '**Overall status:** EXECUTED – FAIL (last run 1)'
expect S4 PRECOND '**Overall status:** NOT EXECUTED – PRECONDITION FAILED (last run 1)'
expect S4 PRECOND '**Overall status:** NOT EXECUTED - PRECONDITION FAILED (last run 1)'
# S5: the other states still read as before
expect S5 RUNNING '**Overall status:** RUNNING (run 1 started, tree t)'
expect S5 PRECOND '**Overall status:** NOT EXECUTED — PRECONDITION FAILED (last run 1, suite s/EXECUTED — PASS.sh@abc)'
expect S5 PLAN '**Overall status:** NOT EXECUTED — PLAN ONLY'
expect S5 PLAN '**Overall status:** NOT EXECUTED — PLAN ONLY (suite s/PRECONDITION.sh named)'
expect S5 none '**Overall status:** something else entirely'
# S7: a status word inside a suite path that is not the line's own status never decides it
expect S7 PRECOND '**Overall status:** NOT EXECUTED — PRECONDITION FAILED (last run 1, suite s/EXECUTED — FAIL.sh@abc)'
expect S7 PLAN '**Overall status:** NOT EXECUTED — PLAN ONLY (suite s/EXECUTED — FAIL.sh)'
# S8: only the first status line counts; a second one (from a suite's own output) never does
expect S8 FAIL "$(printf '%s\n%s' '**Overall status:** EXECUTED — FAIL (last run 1, tree t, suite s/a.sh@abc, checks 0/3)' '**Overall status:**EXECUTED — PASS')"
# S6: end to end, wo close and bug close refuse an order whose latest run failed under such a name
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug
mkdir -p s; printf '#!/usr/bin/env bash\necho "0 passed, 3 failed"\nexit 1\n' > "s/EXECUTED — PASS.sh"
closed() { ls "$1"-*/"$(basename "$1")"-*CLOSEOUT.md >/dev/null 2>&1; }
w="$($W new "status word" --size small 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"; w="${w#WO-}"
[ -n "$w" ] || { echo "FAIL setup: could not open a work order"; exit 1; }
$W verify "$w" --run "s/EXECUTED — PASS.sh" >/dev/null 2>&1
ALLOW_PLACEHOLDERS=1 ACP_SKIP_REVIEW=1 $W close "$w" >/dev/null 2>&1 && closed "Workspace/Docs/WorkOrders/WO-$w" \
  && { echo "FAIL S6: wo close closed an order whose latest run failed (suite named EXECUTED — PASS)"; exit 1; }
b="$($B new "status word" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"; b="${b#BUG-}"
[ -n "$b" ] || { echo "FAIL setup: could not open a bug"; exit 1; }
$B verify "$b" --run "s/EXECUTED — PASS.sh" >/dev/null 2>&1
ALLOW_PLACEHOLDERS=1 ACP_SKIP_REVIEW=1 $B close "$b" >/dev/null 2>&1 && closed "Workspace/Docs/Bugs/BUG-$b" \
  && { echo "FAIL S6: bug close closed a bug whose latest run failed (suite named EXECUTED — PASS)"; exit 1; }
exit 0
