#!/usr/bin/env bash
# report-status: acp intake and acp baseline read a work order's own status line (not any PASS anywhere in
# its files), and the coverage script and intake step 4 accept em dash, en dash and hyphen.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
A=.aicodepipeline/bin/acp; W=.aicodepipeline/bin/wo; WD=Workspace/Docs/WorkOrders
step() { ls -d "$WD"/WO-000"$1"-* 2>/dev/null | head -1; }   # new-project opens intake steps 01..06 as WO-0001..WO-0006
for i in 1 2 3 4 5 6; do [ -d "$(step $i)" ] || { echo "FAIL setup: no intake work order WO-000$i"; exit 1; }; done
doc() { printf '# V\n\n%s\n\n---\n\n## Execution Record\n\n### Run 1\n\n- **Status:** EXECUTED — PASS\n' "$2" > "$(step "$1")/WO-000$1-VERIFICATION.md"; }
doc 1 '**Overall status:** EXECUTED — FAIL (last run 2, tree t, suite s/a.sh@abc, checks 0/3)'   # failed now, passed before
doc 2 '**Overall status:** EXECUTED – PASS (last run 1, tree t, suite s/a.sh@abc, checks 3/3)'   # passed, en dash
doc 3 '**Overall status:** EXECUTED — FAIL (last run 1, tree t, suite s/a.sh@abc, checks 0/3)'   # failed, with a passing copy beside it
doc 4 '**Overall status:** EXECUTED — PASS (last run 1, tree t, suite s/a.sh@abc, checks 3/3)'   # passed, em dash, as wo verify writes it
doc 5 '**Overall status:** EXECUTED - PASS (last run 1, tree t, suite s/a.sh@abc, checks 3/3)'   # passed, hyphen
doc 6 '**Overall status:** EXECUTED — FAIL (last run 1, tree t, suite s/EXECUTED — PASS.sh@abc, checks 0/3)'   # failed; PASS only in the suite name
for c in A-VERIFICATION Z-VERIFICATION; do   # passing copies that sort before and after the document
  printf '# copy\n\n**Overall status:** EXECUTED — PASS (a copy)\n' > "$(step 3)/WO-0003-$c.md"; done
printf '# copy\n\n**Overall status:** EXECUTED — FAIL (a copy)\n' > "$(step 4)/WO-0004-A-VERIFICATION.md"   # a failing copy beside a passing document
# R1: acp intake status reads each step's own status line
st="$($A intake status 2>&1)"
state() { printf '%s\n' "$st" | awk -v s="0$1" '$1==s {print $3; exit}'; }
[ "$(state 1)" = open ] || { echo "FAIL R1: acp intake counted a step whose latest run failed as verified ($(state 1))"; exit 1; }
[ "$(state 2)" = verified ] || { echo "FAIL R1: acp intake did not count an en-dash pass as verified ($(state 2))"; exit 1; }
[ "$(state 3)" = open ] || { echo "FAIL R1: acp intake counted a step by a passing copy beside its failing document ($(state 3))"; exit 1; }
[ "$(state 4)" = verified ] || { echo "FAIL R1: acp intake did not count an em-dash pass as verified ($(state 4))"; exit 1; }
[ "$(state 5)" = verified ] || { echo "FAIL R1: acp intake did not count a hyphen pass as verified ($(state 5))"; exit 1; }
[ "$(state 6)" = open ] || { echo "FAIL R1: acp intake read PASS after the status word, in a failing step's suite name ($(state 6))"; exit 1; }
# R2: acp baseline counts only work orders whose own status line reads PASS (here: WO-0002, WO-0004 and WO-0005)
$A baseline --command true >/dev/null 2>&1 || { echo "FAIL setup: acp baseline did not run"; exit 1; }
grep -qxF -- '- with an executed pass under this tool: 3' Workspace/Testing/results/BASELINE.md \
  || { echo "FAIL R2: acp baseline counted $(sed -n 's/^- with an executed pass under this tool: //p' Workspace/Testing/results/BASELINE.md) passes, not 3"; exit 1; }
# R3: the coverage script reads PASS and FAIL in all three dashes
printf '| Test | Category | Description | Status |\n|---|---|---|---|\n| 1.1 | c | d | EXECUTED — PASS |\n| 1.2 | c | d | EXECUTED – PASS |\n| 1.3 | c | d | EXECUTED - PASS |\n| 1.4 | c | d | EXECUTED – FAIL |\n| 1.5 | c | d | NOT EXECUTED — PLAN ONLY |\n| 1.6 | c | d | EXECUTED - FAIL |\n| 1.7 | c | d | EXECUTED — FAIL |\n' > "$EVAL_TMP/cov.md"
mkdir -p "$EVAL_TMP/results"
cov="$(TEST_RESULTS_DIR="$EVAL_TMP/results" node "$PIPELINE_ROOT/harness/scripts/calculate-coverage.js" "$EVAL_TMP/cov.md" 2>&1)"
printf '%s\n' "$cov" | grep -qE '^  Passed: +3$' && printf '%s\n' "$cov" | grep -qE '^  Failed: +3$' && printf '%s\n' "$cov" | grep -qE '^  Total Tests: +7$' \
  || { echo "FAIL R3: the coverage script did not read the en dash and hyphen: $(printf '%s\n' "$cov" | grep -E 'Total Tests|Passed:|Failed:' | tr -s ' ' | tr '\n' ';')"; exit 1; }
# R3b: the same in the block form ("Test N.N:" then "**Status:**"), in all three dashes
printf '### Test 2.1: a\n**Status:** EXECUTED - PASS\n### Test 2.2: b\n**Status:** EXECUTED – FAIL\n### Test 2.3: c\n**Status:** EXECUTED — PASS\n### Test 2.4: d\n**Status:** EXECUTED - FAIL\n' > "$EVAL_TMP/cov2.md"
cov="$(TEST_RESULTS_DIR="$EVAL_TMP/results" node "$PIPELINE_ROOT/harness/scripts/calculate-coverage.js" "$EVAL_TMP/cov2.md" 2>&1)"
printf '%s\n' "$cov" | grep -qE '^  Passed: +2$' && printf '%s\n' "$cov" | grep -qE '^  Failed: +2$' && printf '%s\n' "$cov" | grep -qE '^  Total Tests: +4$' \
  || { echo "FAIL R3: the coverage script did not read the block form in every dash: $(printf '%s\n' "$cov" | grep -E 'Total Tests|Passed:|Failed:' | tr -s ' ' | tr '\n' ';')"; exit 1; }
# R4: intake step 4 flags an adopted item that records a pass, in any dash, with no run log
for n in 40:– 41:— 42:-; do   # an adopted item per dash: en, em, hyphen
  printf '# Old record %s\n' "${n%%:*}" > "old${n%%:*}.md"
  $W adopt "old${n%%:*}.md" --number "${n%%:*}" >/dev/null 2>&1 || { echo "FAIL setup: wo adopt failed"; exit 1; }
  printf '# V\n\n**Overall status:** EXECUTED %s PASS (typed, never run)\n' "${n#*:}" > "$(ls -d "$WD"/WO-00"${n%%:*}"-* | head -1)/WO-00${n%%:*}-VERIFICATION.md"
done
out="$(bash Workspace/Testing/suites/intake-04-record.sh 2>&1)"
for n in 40:en-dash 41:em-dash 42:hyphen; do
  printf '%s\n' "$out" | grep -qF "records EXECUTED — PASS in WO-00${n%%:*}-VERIFICATION.md with no run log" \
    || { echo "FAIL R4: intake step 4 missed an adopted item's ${n#*:} pass with no run log"; exit 1; }
done
exit 0
