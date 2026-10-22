#!/usr/bin/env bash
set -uo pipefail

cd "$EVAL_TMP"
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }

# copy_of <check>: a fresh installed copy with no evaluations
copy_of() {
  cp -R "$EVAL_TMP/p/.aicodepipeline" "$EVAL_TMP/$1"
  rm -rf "$EVAL_TMP/$1/harness/evals"/*
}
# trivial <check> <name>: a passing evaluation
trivial() {
  mkdir -p "$EVAL_TMP/$1/harness/evals/$2"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$EVAL_TMP/$1/harness/evals/$2/eval.sh"
  chmod +x "$EVAL_TMP/$1/harness/evals/$2/eval.sh"
}
# run_test <check>: run acp test in the copy, keep its exit code in RC
run_test() {
  ( cd "$EVAL_TMP/$1" && PATH=/usr/bin:/bin:$PATH bin/acp test ) > "$EVAL_TMP/$1.log" 2>&1
  RC=$?
}
# stub_eval <check> <line>: replace the copy's bin/eval by a script printing <line> (or nothing)
stub_eval() {
  printf '#!/usr/bin/env bash\n%s\nexit 0\n' "${2:+echo \"$2\"}" > "$EVAL_TMP/$1/bin/eval"
  chmod +x "$EVAL_TMP/$1/bin/eval"
}

# C1: no evaluations
copy_of c1; run_test c1
[ "$RC" -ne 0 ] || { echo "FAIL C1: acp test passed with no evaluations"; exit 1; }
grep -qF '  evaluations FAIL: no evaluations found under harness/evals' "$EVAL_TMP/c1.log" \
  || { echo "FAIL C1: no 'evaluations FAIL: no evaluations found' line"; exit 1; }

# C2: one passing evaluation
copy_of c2; trivial c2 one; run_test c2
{ [ "$RC" -eq 0 ] \
  && grep -qF 'eval-summary: passed=1 failed=0 skipped=0' "$EVAL_TMP/c2.log" \
  && grep -qF '  evaluations: 1 of 1 ran (0 skipped by design)' "$EVAL_TMP/c2.log"; } \
  || { echo "FAIL C2: one passing evaluation did not give a clean count"; exit 1; }

# C3: a source-only evaluation is skipped in an installed copy, by design
copy_of c3; trivial c3 one; trivial c3 two; : > "$EVAL_TMP/c3/harness/evals/two/.source-only"; run_test c3
{ [ "$RC" -eq 0 ] \
  && grep -qF 'eval-summary: passed=1 failed=0 skipped=1' "$EVAL_TMP/c3.log" \
  && grep -qF '  evaluations: 1 of 2 ran (1 skipped by design)' "$EVAL_TMP/c3.log"; } \
  || { echo "FAIL C3: a source-only skip in an installed copy was not counted as by design"; exit 1; }

# C4: eval run prints no summary
copy_of c4; trivial c4 one; stub_eval c4 ""; run_test c4
{ [ "$RC" -ne 0 ] && grep -qF '  evaluations FAIL: eval run printed no summary line' "$EVAL_TMP/c4.log"; } \
  || { echo "FAIL C4: acp test passed without an eval summary"; exit 1; }

# C5: fewer evaluations ran than exist
copy_of c5; trivial c5 one; trivial c5 two; stub_eval c5 "eval-summary: passed=1 failed=0 skipped=0"; run_test c5
{ [ "$RC" -ne 0 ] && grep -qF '  evaluations FAIL: 1 ran and 0 skipped, but 2 exist (0 may be skipped here)' "$EVAL_TMP/c5.log"; } \
  || { echo "FAIL C5: acp test passed when fewer evaluations ran than exist"; exit 1; }

# C6: an unknown name is refused before anything is written
copy_of c6; trivial c6 one; rm -rf "$EVAL_TMP/c6/harness/evals/results"
( cd "$EVAL_TMP/c6" && PATH=/usr/bin:/bin:$PATH bin/eval run does-not-exist ) > /dev/null 2> "$EVAL_TMP/c6.err"
RC=$?
{ [ "$RC" -eq 2 ] && grep -qF "no evaluation named 'does-not-exist'" "$EVAL_TMP/c6.err" && [ ! -e "$EVAL_TMP/c6/harness/evals/results" ]; } \
  || { echo "FAIL C6: eval run wrote a results file before refusing an unknown name"; exit 1; }

# C7: skips where none may be skipped (the pipeline repository's rule is 0; here, no .source-only)
copy_of c7; trivial c7 one; trivial c7 two; stub_eval c7 "eval-summary: passed=0 failed=0 skipped=2"; run_test c7
{ [ "$RC" -ne 0 ] && grep -qF '  evaluations FAIL: 0 ran and 2 skipped, but 2 exist (0 may be skipped here)' "$EVAL_TMP/c7.log"; } \
  || { echo "FAIL C7: acp test passed when evaluations were skipped that may not be"; exit 1; }

# C8: the summary reports a failure but eval run exited 0 (two-digit counts on purpose)
copy_of c8; for i in 01 02 03 04 05 06 07 08 09 10 11; do trivial c8 "e$i"; done
stub_eval c8 "eval-summary: passed=10 failed=1 skipped=0"; run_test c8
{ [ "$RC" -ne 0 ] && grep -qF '  evaluations FAIL: eval run reported 1 failed but exited 0' "$EVAL_TMP/c8.log"; } \
  || { echo "FAIL C8: acp test passed when eval run reported a failure but exited 0"; exit 1; }

exit 0
