#!/usr/bin/env bash
# gate-log: the evidence gate and acp check read only <ID>-VERIFICATION.md, never a suite's raw log or
# another *VERIFICATION*.md, and the status reader reads spacing exactly as the drivers do.
set -uo pipefail
GATE="$PIPELINE_ROOT/core/hooks/evidence-gate.py"
R="$EVAL_TMP/repo"; mkdir -p "$R" && cd "$R" && git init -q || { echo "FAIL setup: could not make a scratch repository"; exit 1; }
order() { # <name> <status line in VERIFICATION.md> <line written into another file> [<that file's name>]
  local d="Workspace/Docs/WorkOrders/WO-0001-$1"; rm -rf Workspace; mkdir -p "$d"
  printf '# closeout\n' > "$d/WO-0001-CLOSEOUT.md"
  printf '# V\n\n%s\n' "$2" > "$d/WO-0001-VERIFICATION.md"
  printf '%s\n' "$3" > "$d/${4:-WO-0001-VERIFICATION-20261019-120000-1.log}"; CLOSEOUT="$d/WO-0001-CLOSEOUT.md"; }
gate() { out="$(cd "$R" && ACP_EVIDENCE_GATE=block python3 -I "$GATE" < /dev/null 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || { echo "FAIL setup: the evidence gate exited $rc: $out"; exit 1; }; }
# G1: a failing run whose suite printed a PASS status line into its log is still blocked
order g1 '**Overall status:** EXECUTED — FAIL (last run 1, tree t, suite s/a.sh@abc, checks 0/3)' '**Overall status:** EXECUTED — PASS (forged)'
gate; [ "$rc" -eq 2 ] || { echo "FAIL G1: the evidence gate passed a closeout whose VERIFICATION.md failed (it read the suite log)"; exit 1; }
printf '%s\n' "$out" | grep -qF "the latest verification run is EXECUTED — FAIL" || { echo "FAIL G1: the evidence gate blocked without naming the failed run"; exit 1; }
# G1b: another *VERIFICATION*.md reading PASS (a copy, a UI note) does not count either, in the gate or in acp check
for extra in WO-0001-VERIFICATION-UI.md WO-0001-VERIFICATION-old.md WO-0001-UI-VERIFICATION.md; do
  order g1b '**Overall status:** EXECUTED — FAIL (last run 1)' '**Overall status:** EXECUTED — PASS (a copy)' "$extra"
  gate; [ "$rc" -eq 2 ] || { echo "FAIL G1b: the evidence gate passed a failing run because of $extra"; exit 1; }
  cout="$(cd "$R" && python3 -I "$PIPELINE_ROOT/core/hooks/check.py" --root "$R" --paths "$CLOSEOUT" --no-kb 2>&1)"; crc=$?
  [ "$crc" -eq 2 ] || { echo "FAIL G1b: acp check passed a failing run because of $extra (exit $crc)"; exit 1; }
  # and the copy alone, with no document, is no document at all (whatever order the folder lists in)
  rm -f "$(dirname "$CLOSEOUT")/WO-0001-VERIFICATION.md"
  gate; [ "$rc" -eq 2 ] || { echo "FAIL G1b: the evidence gate took $extra as the document"; exit 1; }
  cout="$(cd "$R" && python3 -I "$PIPELINE_ROOT/core/hooks/check.py" --root "$R" --paths "$CLOSEOUT" --no-kb 2>&1)"; crc=$?
  [ "$crc" -eq 2 ] || { echo "FAIL G1b: acp check took $extra as the document (exit $crc)"; exit 1; }
done
# G2: a passing run whose suite printed a FAIL status line into its log passes
order g2 '**Overall status:** EXECUTED — PASS (last run 1, tree t, suite s/a.sh@abc, checks 3/3)' '**Overall status:** EXECUTED — FAIL (from the suite)'
gate; [ "$rc" -eq 0 ] || { echo "FAIL G2: the evidence gate blocked a passing run because of its suite log: $out"; exit 1; }
# G3: the gate's reader agrees with both drivers' on hand-edited spacing and line ends
eval "wo_$(sed -n '/^latest_status() {/,/^}/p' "$PIPELINE_ROOT/bin/wo")"
eval "bug_$(sed -n '/^latest_status() {/,/^}/p' "$PIPELINE_ROOT/bin/bug")"
type wo_latest_status >/dev/null 2>&1 && type bug_latest_status >/dev/null 2>&1 || { echo "FAIL setup: could not read latest_status from the drivers"; exit 1; }
py_status() { python3 -I -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("eg",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.latest_status(sys.argv[2]))' "$GATE" "$1"; }
n=0
agree() { # <id> <expected> <file body, printf format>
  n=$((n+1)); f="$EVAL_TMP/v$n.md"; printf "$3" > "$f"
  for r in wo bug py; do
    case "$r" in wo) got="$(wo_latest_status "$f")";; bug) got="$(bug_latest_status "$f")";; py) got="$(py_status "$f")";; esac
    [ "$got" = "$2" ] || { echo "FAIL $1: $r reads case $n as $got, not $2"; exit 1; }
  done; }
agree G3 PASS '**Overall status:** EXECUTED — PASS (x)\n'
agree G3 PASS '**Overall status:** EXECUTED – PASS (en dash)\n'
agree G3 PASS '**Overall status:**EXECUTED — PASS (no space after the marker)\n'
agree G3 none '**Overall status:**  EXECUTED — PASS (two spaces)\n'
agree G3 none '**Overall status:**\tEXECUTED — PASS (a tab)\n'
agree G3 none '**Overall status:** EXECUTED—PASS (no spaces round the dash)\n'
agree G3 none '**Overall status:** EXECUTED -- PASS (two hyphens)\n'
agree G3 FAIL '**Overall status:** EXECUTED — FAIL (x)\r**Overall status:** EXECUTED — PASS (after a lone CR)\n'
agree G3 FAIL '**Overall status:** EXECUTED — FAIL (crlf)\r\n'
agree G3 PRECOND '**Overall status:** NOT EXECUTED – PRECONDITION FAILED (x)\n'
agree G3 none 'x\r**Overall status:** EXECUTED — PASS (only after a lone CR)\n'
agree G3 PLAN '**Overall status:** NOT EXECUTED—PRECONDITION FAILED (no spaces round the dash)\n'
agree G3 FAIL '\377**Overall status:** EXECUTED — PASS (after an invalid byte)\n\n**Overall status:** EXECUTED — FAIL (x)\n'
agree G3 none 'a\000b\n**Overall status:** EXECUTED — PASS (a file holding a NUL)\n'
exit 0
