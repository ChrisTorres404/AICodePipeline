#!/usr/bin/env bash
# acp-paths: bin/acp fills the pipeline's path into what it writes as data: intake's specs and suites,
# the CI workflow (which refuses a path the workflow's shell would split or run), and command/skill text.
set -uo pipefail
# the project sits under a folder holding [1], so a root used as a pattern rather than a literal shows
mkdir -p "$EVAL_TMP/w[1]" && cd "$EVAL_TMP/w[1]" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 || { echo "FAIL setup: could not commit"; exit 1; }
P="$EVAL_TMP/w[1]/p"
copy() { mkdir -p "$P/$1" && (cd "$PIPELINE_ROOT" && tar -cf - --exclude ./harness/evals/results --exclude ./.git --exclude ./dist .) | (cd "$P/$1" && tar -xf -) || { echo "FAIL setup: could not copy the pipeline to $1"; exit 1; }; }
WF=.github/workflows/acp-check.yml
# I1: intake from a pipeline whose path holds | writes each spec with that path in it, and each suite whole
copy "x|y/acp"
for d in Workspace/Docs/WorkOrders/WO-*/; do grep -q '^intake=' "$d.wo-meta" 2>/dev/null && rm -rf "$d"; done; rm -f Workspace/Testing/suites/intake-*.sh   # intake ran at install; run it afresh
out="$("$P/x|y/acp/bin/acp" intake 2>&1)"; rc=$?
s="$(ls Workspace/Docs/WorkOrders/WO-*/WO-*-SPEC.md 2>/dev/null | xargs grep -l 'fingerprint' 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && [ -n "$s" ] && grep -qF '`x|y/acp/bin/wo fingerprint`' "$s" && ! grep -qF '{{PIPELINE_ROOT}}' "$s" && ! grep -qF 'WO-XXXX' "$s" && grep -qx "# $(basename "$s" -SPEC.md): .*" "$s"; } \
  || { echo "FAIL I1: acp intake did not write the pipeline's path into its specs as it is"; echo "  exit $rc"; exit 1; }
for f in "$P/x|y/acp"/core/templates/intake/intake-*.sh; do
  cmp -s "$f" "Workspace/Testing/suites/$(basename "$f")" || { echo "FAIL I1: acp intake did not copy an intake suite whole"; echo "  $(basename "$f")"; exit 1; }
done
# I2: acp ci github refuses a pipeline path the workflow's shell would split or run (|, ;, a space), writing nothing
for q in 'x|y' 'tools;x' 'my tools'; do
  [ -d "$P/$q/acp" ] || copy "$q/acp"; rm -f "$WF"
  out="$(bash "$P/$q/acp/bin/acp" ci github 2>&1)"; rc=$?
  { [ "$rc" -ne 0 ] && [ ! -e "$WF" ] && printf '%s\n' "$out" | grep -qF "the workflow would split or run"; } \
    || { echo "FAIL I2: acp ci github wrote a workflow from a pipeline path its shell would split or run"; echo "  path holding '$q', exit $rc: $out"; exit 1; }
done
# I3: an ordinary path is written as it is
copy "my-tools.v2/acp"; rm -f "$WF"
bash "$P/my-tools.v2/acp/bin/acp" ci github >/dev/null 2>&1 && grep -qF 'my-tools.v2/acp/bin/acp check --since HEAD~1' "$WF" && ! grep -qF '{{PIPELINE_ROOT}}' "$WF" \
  || { echo "FAIL I3: acp ci github did not write an ordinary pipeline path"; exit 1; }
# I4: acp command and acp skill print their text with the path filled in, from a path holding |, under a root holding [1]
for q in 'x|y'; do
  out="$(bash "$P/$q/acp/bin/acp" command wo 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "\`$q/acp/bin/wo\`" && ! printf '%s\n' "$out" | grep -qF '{{PIPELINE_ROOT}}' && ! printf '%s\n' "$out" | grep -qF "$P/"; } \
    || { echo "FAIL I4: acp command did not print its text with the pipeline's path filled in"; echo "  path holding '$q', exit $rc"; exit 1; }
  out="$(bash "$P/$q/acp/bin/acp" skill behavioral-testing 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$q/acp/harness/runners/run-all-critical-tests.sh --quick" && ! printf '%s\n' "$out" | grep -qF '{{PIPELINE_ROOT}}' && ! printf '%s\n' "$out" | grep -qF "$P/"; } \
    || { echo "FAIL I4: acp skill did not print its text with the pipeline's path filled in"; echo "  path holding '$q', exit $rc"; exit 1; }
done
exit 0
