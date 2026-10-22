#!/usr/bin/env bash
# prompt-priority: the Prompt template's priority line has the form render fills, so a work order's Prompt
# document carries the priority it was opened with, as its other documents do.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
W=.aicodepipeline/bin/wo; D=Workspace/Docs/WorkOrders
# Q1: the Prompt document of a work order opened with --priority P0 says P0
$W new "alpha" --size standard --priority P0 >/dev/null 2>&1 || { echo "FAIL setup: wo new failed"; exit 1; }
f="$(ls "$D"/WO-*-alpha/WO-*-Prompt.md 2>/dev/null | head -1)"; [ -n "$f" ] || { echo "FAIL setup: no Prompt document was written"; exit 1; }
{ [ "$(grep -c -i 'priority' "$f")" = 1 ] && grep -qxF '**Priority:** P0' "$f"; } \
  || { echo "FAIL Q1: the Prompt document does not carry the priority it was opened with: $(grep -i -m1 'priority' "$f")"; exit 1; }
# Q2: with no --priority it says P2, the default
$W new "beta" --size standard >/dev/null 2>&1; f="$(ls "$D"/WO-*-beta/WO-*-Prompt.md | head -1)"
grep -qxF '**Priority:** P2' "$f" || { echo "FAIL Q2: the Prompt document does not carry the default priority: $(grep -i -m1 'priority' "$f")"; exit 1; }
# Q3: every document a large work order is opened with carries the same priority, and none keeps the choice list
$W new "gamma" --size large --priority P1 --sdk --ui >/dev/null 2>&1 || { echo "FAIL setup: wo new --size large failed"; exit 1; }
g="$(ls -d "$D"/WO-*-gamma | head -1)"; n=0
for f in "$g"/*.md; do
  grep -q '^\*\*Priority:\*\*' "$f" || continue; n=$((n+1))
  grep -qxF '**Priority:** P1' "$f" || { echo "FAIL Q3: $(basename "$f") does not carry the priority: $(grep -m1 '^\*\*Priority:\*\*' "$f")"; exit 1; }
done
{ [ "$n" -ge 2 ] && grep -qxF '**Priority:** P1' "$g"/WO-*-Prompt.md && grep -qxF '**Priority:** P1' "$g"/WO-*-SPEC.md; } \
  || { echo "FAIL Q3: the large work order's Prompt and SPEC do not both carry the priority ($n documents do)"; exit 1; }
! grep -rlF -e '[P0/P1/P2/P3]' -e 'P0 | P1 | P2 | P3' "$g" >/dev/null || { echo "FAIL Q3: a document still holds the priority choice list: $(grep -rlF -e '[P0/P1/P2/P3]' -e 'P0 | P1 | P2 | P3' "$g")"; exit 1; }
exit 0
