#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
cd "$EVAL_TMP"; "$PIPELINE_ROOT/bin/new-project" proj --name Proj --no-git >/dev/null
cd proj; W=./.aicodepipeline/bin/wo; B=./.aicodepipeline/bin/bug
n="$($W new "Eval order" --size trivial --area backend | grep -o 'WO-[0-9]*' | head -1)"; n="${n#WO-}"
rc=0; $W close "$n" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "closed with no verification"; exit 1; }
$W verify "$n" >/dev/null                                   # plan only
rc=0; $W close "$n" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "closed on NOT EXECUTED — PLAN ONLY"; exit 1; }
printf '#!/usr/bin/env bash\nexit 1\n' > fail.sh; chmod +x fail.sh
$W verify "$n" --run ./fail.sh >/dev/null 2>&1 || true       # executed, failed
rc=0; $W close "$n" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "closed on EXECUTED — FAIL"; exit 1; }
rc=0; $W promote "$n" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "promoted on EXECUTED — FAIL"; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > pass.sh; chmod +x pass.sh
$W verify "$n" --run ./pass.sh >/dev/null                    # executed, passed
fill_wo "$n"; $W close "$n" >/dev/null || { echo "close refused after EXECUTED — PASS"; exit 1; }
$W show "$((10#$n))" >/dev/null || { echo "unpadded number not accepted"; exit 1; }
rc=0; $W promote "$n" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "promoted a closeout that still had template placeholders"; exit 1; }
perl -pi -e 's/\[Lesson 1\]/Suites must clean up what they create/; s/\[Lesson 2\]/Assert on the record you made, not on collection size/; s/\[Lesson 3\]/Re-run the original suite after every fix/' "Workspace/Docs/WorkOrders/WO-$n-eval-order/WO-$n-CLOSEOUT.md"
$W promote "$n" >/dev/null || { echo "promote refused after PASS with pitfalls filled"; exit 1; }
$W promote "$n" >/dev/null || { echo "re-promote failed"; exit 1; }
[ "$(grep -c "^## WO-$n " .aicodepipeline/playbooks/proj/CATALOG.md)" -eq 1 ] || { echo "re-promote duplicated the catalog entry"; exit 1; }
grep -q "Suites must clean up" .aicodepipeline/playbooks/proj/CATALOG.md || { echo "catalog entry lacks the pitfalls"; exit 1; }
[ -d ".aicodepipeline/playbooks/proj/workorders/WO-$n-eval-order" ] || { echo "promote nested the playbook path wrongly:"; find .aicodepipeline/playbooks -maxdepth 3 -type d; exit 1; }
b="$($B new "Eval bug" --category api | grep -o 'BUG-[0-9]*' | head -1)"; b="${b#BUG-}"
$B verify "$b" >/dev/null
rc=0; $B close "$b" >/dev/null 2>&1 || rc=$?; [ "$rc" -ne 0 ] || { echo "bug closed on plan-only verification"; exit 1; }
$B verify "$b" --run ./pass.sh >/dev/null
fill_bug "$b"; $B close "$b" >/dev/null || { echo "bug close refused after PASS"; exit 1; }
grep -q "Eval bug" "$(ls -d Workspace/Docs/Bugs/BUG-$b-*)"/BUG-$b-*.md || { echo "bug title not written into the issue document"; exit 1; }
exit 0
