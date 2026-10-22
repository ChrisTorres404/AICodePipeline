#!/usr/bin/env bash
# gate-paths: the evidence gate reads git status with -z, so a work order whose path holds a space, a
# non-ASCII letter or a double quote is checked, not skipped.
set -uo pipefail
GATE="$PIPELINE_ROOT/core/hooks/evidence-gate.py"
n=0
case_repo() { # <folder path> <status line>: a scratch repository holding one closed order with that status
  n=$((n+1)); R="$EVAL_TMP/r$n"; mkdir -p "$R" && git -C "$R" init -q || { echo "FAIL setup: could not make a scratch repository"; exit 1; }
  order "$1" "$2"; }
order() { # <folder path> <status line>: one more closed order in the current scratch repository
  mkdir -p "$R/$1" || { echo "FAIL setup: could not make $1"; exit 1; }
  local id; id="$(basename "$1" | cut -d- -f1-2)"
  printf '# closeout\n' > "$R/$1/$id-CLOSEOUT.md"; printf '# V\n\n%s\n' "$2" > "$R/$1/$id-VERIFICATION.md"; }
gate() { out="$(cd "$R" && ACP_EVIDENCE_GATE=block python3 -I "$GATE" < /dev/null 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || { echo "FAIL setup: the evidence gate exited $rc: $out"; exit 1; }; }
FAILED='**Overall status:** EXECUTED — FAIL (last run 1)'; PASSED='**Overall status:** EXECUTED — PASS (last run 1)'
# G1: a folder under a path holding a space is checked
case_repo "Work Orders/WO-0001-x" "$FAILED"; gate
[ "$rc" -eq 2 ] || { echo "FAIL G1: the evidence gate skipped a failing order under a path holding a space"; exit 1; }
printf '%s\n' "$out" | grep -qF "WO-0001-x: the latest verification run is EXECUTED — FAIL" || { echo "FAIL G1: the gate blocked without naming the order: $out"; exit 1; }
# G2: a folder whose name holds a non-ASCII letter is checked
case_repo "Docs/WO-0002-café" "$FAILED"; gate
[ "$rc" -eq 2 ] || { echo "FAIL G2: the evidence gate skipped a failing order whose path holds a non-ASCII letter"; exit 1; }
# G3: a folder whose name holds a double quote is checked
case_repo 'Docs/WO-0003-a"b' "$FAILED"; gate
[ "$rc" -eq 2 ] || { echo "FAIL G3: the evidence gate skipped a failing order whose path holds a double quote"; exit 1; }
# G4: a staged rename of the closeout is followed to its new path
case_repo "Docs/WO-0004-x" "$FAILED"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base && git -C "$R" mv "Docs/WO-0004-x" "Docs/WO-0004-y" || { echo "FAIL setup: could not rename"; exit 1; }
gate; [ "$rc" -eq 2 ] || { echo "FAIL G4: the evidence gate skipped a failing order whose folder was renamed"; exit 1; }
# G5: a passing order under such a path passes
case_repo "Work Orders/WO-0005-café \"q\"" "$PASSED"; gate
[ "$rc" -eq 0 ] || { echo "FAIL G5: the evidence gate blocked a passing order: $out"; exit 1; }
# G6: every entry is read, not only the first: the failing order sorts after a passing one
case_repo "Docs/WO-0006-a" "$PASSED"; order "Docs/WO-0006-b c" "$FAILED"; gate
[ "$rc" -eq 2 ] || { echo "FAIL G6: the evidence gate read only the first entry of git status"; exit 1; }
# G7: a path holding a byte that is not UTF-8 (here an index entry) does not blind the gate
case_repo "Docs/WO-0007-x" "$FAILED"; h="$(git -C "$R" hash-object -w --stdin < /dev/null)"
printf '100644 %s\tnotes-caf\351.txt\n' "$h" | git -C "$R" update-index --index-info || { echo "FAIL setup: could not add the index entry"; exit 1; }
gate; [ "$rc" -eq 2 ] || { echo "FAIL G7: a path that is not UTF-8 made the evidence gate check nothing"; exit 1; }
# G8: an entry after a staged rename and a modified file is still read (the parse stays in step;
# A/ and C.txt sort before Docs/, so the order's entry comes after them)
case_repo "Docs/WO-0008-x" "$FAILED"; mkdir -p "$R/A"; printf 'a\n' > "$R/A/a.txt"; printf 'c\n' > "$R/C.txt"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base && git -C "$R" mv A/a.txt A/b.txt \
  && printf 'c2\n' > "$R/C.txt" && printf '# closeout, edited\n' > "$R/Docs/WO-0008-x/WO-0008-CLOSEOUT.md" || { echo "FAIL setup: could not stage G8"; exit 1; }
gate; [ "$rc" -eq 2 ] || { echo "FAIL G8: the evidence gate lost an entry that came after a rename"; exit 1; }
# G9: a top-level folder whose name starts with a space is checked
case_repo " Docs/WO-0009-x" "$FAILED"; gate
[ "$rc" -eq 2 ] || { echo "FAIL G9: the evidence gate skipped a failing order under a path starting with a space"; exit 1; }
# G10: moving a file out of a failing order's folder does not hide the folder
case_repo "Docs/WO-0010-x" "$FAILED"; printf 'n\n' > "$R/Docs/WO-0010-x/notes.md"
git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base && git -C "$R" mv "Docs/WO-0010-x/notes.md" other.md \
  || { echo "FAIL setup: could not stage G10"; exit 1; }
gate; [ "$rc" -eq 2 ] || { echo "FAIL G10: moving a file out of a failing order's folder hid the folder from the gate"; exit 1; }
exit 0
