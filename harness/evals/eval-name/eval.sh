#!/usr/bin/env bash
# eval-name: eval run <name> runs exactly that evaluation, or refuses; it never runs nothing and exits 0.
set -uo pipefail
R="$EVAL_TMP/r"; mkdir -p "$R/bin" "$R/harness/evals/x" "$R/harness/evals/.h" "$R/harness/evals/f"
cp "$PIPELINE_ROOT/bin/eval" "$R/bin/eval"; : > "$R/pipeline.config.example.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/harness/evals/x/eval.sh"; printf '# x\n\nProves: nothing.\n' > "$R/harness/evals/x/README.md"
cp "$R/harness/evals/x/eval.sh" "$R/harness/evals/.h/eval.sh"
run() { out="$(cd "$R" && bash bin/eval run "$1" 2>&1)"; rc=$?; }
results() { ls "$R/harness/evals/results" 2>/dev/null | grep -c . || true; }
# an earlier run's record, which no refused run may touch
mkdir -p "$R/harness/evals/results"; printf '# earlier run\n' > "$R/harness/evals/results/keep.md"
# E1: a name with a trailing slash names a folder the run never matches: refused, not run as nothing
run "x/"; [ "$rc" -eq 2 ] || { echo "FAIL E1: eval run x/ ran nothing and exited $rc"; exit 1; }
err="$(cd "$R" && bash bin/eval run "x/" 2>&1 >/dev/null)"
printf '%s\n' "$err" | grep -qF "eval run: 'x/' matched no evaluation folder, so nothing ran" || { echo "FAIL E1: eval run x/ refused without saying, on stderr, that nothing ran"; exit 1; }
# E2: other path forms, and a folder the run loop never visits (a dot folder), are refused the same way
for p in ./x ../evals/x .h; do
  run "$p"; [ "$rc" -eq 2 ] || { echo "FAIL E2: eval run $p exited $rc, not 2"; exit 1; }
  printf '%s\n' "$out" | grep -qF "eval run: '$p' matched no evaluation folder, so nothing ran" || { echo "FAIL E2: eval run $p refused without saying nothing ran"; exit 1; }
done
# E3: a refused run leaves no results file behind
[ "$(results)" = 1 ] && [ -f "$R/harness/evals/results/keep.md" ] || { echo "FAIL E3: a refused run left a results file or removed an earlier one"; exit 1; }
# E4: a plain name still runs exactly that evaluation
run "x"; [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "1 passed, 0 failed" || { echo "FAIL E4: eval run x no longer runs x (exit $rc)"; exit 1; }
# E5: an unknown name is refused as before
run "nosuch"; [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "no evaluation named 'nosuch'" || { echo "FAIL E5: eval run nosuch is no longer refused as before (exit $rc)"; exit 1; }
# E6: a named evaluation that fails is reported as failed (exit 1), not refused as matching nothing
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/harness/evals/f/eval.sh"
run "f"; [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "0 passed, 1 failed" || { echo "FAIL E6: eval run f did not report its failure (exit $rc)"; exit 1; }
# E7: in an installed copy, a named source-only evaluation is skipped (exit 0), not refused
rm -f "$R/pipeline.config.example.sh"; : > "$R/harness/evals/x/.source-only"
run "x"; [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "0 passed, 0 failed, 1 skipped" || { echo "FAIL E7: eval run x in an installed copy was not skipped (exit $rc)"; exit 1; }
exit 0
