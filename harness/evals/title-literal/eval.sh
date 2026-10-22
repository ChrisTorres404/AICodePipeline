#!/usr/bin/env bash
# title-literal: wo and bug put titles and the priority into documents as data, never as sed code.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p && git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm base >/dev/null 2>&1 \
  || { echo "FAIL setup: could not make the scratch project's first commit"; exit 1; }
W=.aicodepipeline/bin/wo; B=.aicodepipeline/bin/bug
mkdir -p "$EVAL_TMP/out"

# T1: a work-order title is written literally into the SPEC's first line
for t in 'a/b' 'x & y' 'back\slash' 'dollar $HOME \1' "z/w $EVAL_TMP/out" 'date YYYY-MM-DD' 'ref WO-XXXX [Title]'; do
  n="$($W new "$t" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
  f="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-SPEC.md 2>/dev/null | head -1)"
  { [ -n "$n" ] && [ -f "$f" ] && [ "$(head -1 "$f")" = "# $n: $t" ]; } || { echo "FAIL T1: wo new refused or mangled the title [$t]"; exit 1; }
done

# T2: no title ran as a sed write command
[ -z "$(ls -A "$EVAL_TMP/out")" ] || { echo "FAIL T2: a title ran as a sed write command"; exit 1; }

# T3: the priority is written literally; only P0 to P3 are taken, so one holding sed code is refused
$W new "priority bad" --priority 'P1 & /x' >/dev/null 2>&1 && { echo "FAIL T3: a priority holding sed code was taken"; exit 1; }
n="$($W new "priority check" --priority P1 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
f="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-SPEC.md 2>/dev/null | head -1)"
{ [ -f "$f" ] && grep -qxF '**Priority:** P1' "$f"; } || { echo "FAIL T3: the priority was not written literally"; exit 1; }

# T4: a bug title is written literally into the issue's first line
for t in 'a/b' 'x & y' 'back\slash' 'a [Short Title] b' 'see BUG-XXXX'; do
  n="$($B new "$t" --category database 2>/dev/null | grep -o 'BUG-[0-9][0-9]*' | head -1)"
  f="$(ls Workspace/Docs/Bugs/"$n"-*/"$n"-*.md 2>/dev/null | grep -v -e VERIFICATION -e Prompt -e CLOSEOUT | head -1)"
  { [ -n "$n" ] && [ -f "$f" ] && [ "$(head -1 "$f")" = "# $n: $t" ]; } || { echo "FAIL T4: bug new refused or mangled the title [$t]"; exit 1; }
done

# T5: bug verify still titles its document (render_v)
d="$(ls -d Workspace/Docs/Bugs/"$n"-* | head -1)"
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > "$EVAL_TMP/suite.sh"
$B verify "${n#BUG-}" --run "$EVAL_TMP/suite.sh" >/dev/null 2>&1
v="$d/$n-VERIFICATION.md"
{ [ -f "$v" ] && [ "$(head -1 "$v")" = "# $n: $(basename "$d") - Verification Report" ]; } || { echo "FAIL T5: bug verify did not title its document"; exit 1; }
# T6: a PERL_UNICODE setting in the user's environment does not re-encode the title
t='café 日本'
n="$(PERL_UNICODE=SDA $W new "$t" 2>/dev/null | grep -o 'WO-[0-9][0-9]*' | head -1)"
f="$(ls Workspace/Docs/WorkOrders/"$n"-*/"$n"-SPEC.md 2>/dev/null | head -1)"
{ [ -f "$f" ] && [ "$(head -1 "$f")" = "# $n: $t" ]; } || { echo "FAIL T6: PERL_UNICODE in the environment changed the title"; exit 1; }
exit 0
