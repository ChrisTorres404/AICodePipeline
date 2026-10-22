#!/usr/bin/env bash
# Every harness runner writes to the one results directory, and the
# manifest-driven report script starts at all.
set -uo pipefail
cd "$PIPELINE_ROOT" || { echo "no PIPELINE_ROOT"; exit 1; }

fail() { echo "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; exit 1; }

# --- the shared resolver exists and is what the entry points use ------------
[ -f harness/lib/paths.sh ] || fail "harness/lib/paths.sh is missing: each script would resolve its own results directory"
for s in harness/runners/run-all-critical-tests.sh harness/runners/test-runner.sh harness/scripts/run-behavioral-tests.sh; do
  [ -f "$s" ] || fail "missing runner: $s"
  grep -q 'lib/paths.sh' "$s" || fail "$s does not use the shared path resolution"
done

# --- the report script must start with nothing set --------------------------
# It used to read SUITES_DIR two lines before assigning it, which under set -u
# killed the script before it ran anything.
out="$(env -u SUITES_DIR -u SUITES_MANIFEST TEST_RESULTS_DIR="$EVAL_TMP/nowhere" \
        bash harness/scripts/run-behavioral-tests.sh 2>&1)"
case "$out" in
  *"unbound variable"*) fail "the report script dies before it runs anything" "$out";;
esac
case "$out" in
  *"No suite manifest at "[[:space:]]*|*"No suite manifest at"$'\n'*) fail "the manifest path resolved to nothing" "$out";;
esac

# --- a run writes under <testing>/results, and nowhere else -----------------
W="$EVAL_TMP/ws"; mkdir -p "$W/suites" "$W/results"
printf 'essential|unit|ok.sh|Ok suite\n' > "$W/suites.manifest"
printf '#!/usr/bin/env bash\necho "check: ok"\nexit 0\n' > "$W/suites/ok.sh"

SUITES_DIR="$W/suites" bash harness/scripts/run-behavioral-tests.sh >/dev/null 2>&1
ls "$W/results"/behavioral-test-report_*.md >/dev/null 2>&1 \
  || fail "the report was not written to the results directory the installer creates"
[ -f "$W/results/summary.txt" ] || fail "no summary beside the report"
[ -e "$W/test-results" ] && fail "a test-results directory was created: evidence would land in the fingerprinted tree"

SUITES_DIR="$W/suites" bash harness/runners/test-runner.sh --list >/dev/null 2>&1 \
  || fail "the interactive runner cannot list the inventory"
[ -e "$W/test-results" ] && fail "the interactive runner created test-results"

# A check that cannot run must not pass: without node the coverage check would be skipped silently.
command -v node >/dev/null 2>&1 || fail "node is not on PATH: the coverage summary check cannot run"
printf '| 1.1 | Thing | Does a thing | EXECUTED — PASS |\n' > "$W/v.md"
TEST_RESULTS_DIR="$W/results" node harness/scripts/calculate-coverage.js "$W/v.md" >/dev/null 2>&1
[ -f "$W/results/coverage-summary.txt" ] \
  || fail "the coverage summary did not land in the results directory"
[ -e "$W/test-results" ] && fail "the coverage report created test-results"

# --- the old name is gone from everything that ships ------------------------
hits="$(grep -rn 'test-results' harness core docs 2>/dev/null | grep -v '^harness/evals/' || true)"
[ -n "$hits" ] && fail "the abandoned results directory name is still referenced" "$hits"

# --- the duplicate runners are gone, and unreferenced -----------------------
for gone in harness/runners/run-all-tests.sh harness/scripts/run-test-suite.sh; do
  [ -e "$gone" ] && fail "$gone was reinstated: two runners doing one job drift apart"
done
refs="$(grep -rn 'run-all-tests\.sh\|run-test-suite\.sh' harness core docs bin 2>/dev/null | grep -v '^harness/evals/' || true)"
[ -n "$refs" ] && fail "a deleted runner is still referenced" "$refs"

exit 0
