#!/usr/bin/env bash
# template-missing: a template that is missing or cannot be read is refused, with its path, before anything is
# written: perl only warns "Can't open" and exits 0, so wo, bug and acp kept an empty file and said done.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" base --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
A=.aicodepipeline; T=$A/core/templates; WD=Workspace/Docs/WorkOrders; BD=Workspace/Docs/Bugs; SU=Workspace/Testing/suites
[ -f "base/$T/workorders/WO-TEMPLATE-CHECKLIST.md" ] && [ -f "base/$T/ci/acp-check.yml" ] || { echo "FAIL setup: the installed copy has no templates where expected"; exit 1; }
n=0
fresh() { n=$((n+1)); cd "$EVAL_TMP" && rm -rf "p$n" && cp -R base "p$n" && cd "p$n" || { echo "FAIL setup: could not copy the project"; exit 1; }; }
run() { err="$("$@" 2>&1 >/dev/null)"; rc=$?; }
refused() { # <case> <driver prefix> <path suffix>: exit 1 and the refusal line naming the template
  [ "$rc" -eq 1 ] && printf '%s\n' "$err" | grep -F "$2: template missing or unreadable: " | grep -qF "$3" \
    || { echo "FAIL $1: no refusal naming $3 (exit $rc): $err"; exit 1; }; }
# E1: wo new with a template missing refuses and leaves no folder (the half-made-folder cleanup fires)
fresh; rm "$T/workorders/WO-TEMPLATE-CHECKLIST.md"
run $A/bin/wo new "Missing tpl" --size standard
[ "$rc" -ne 0 ] || { echo "FAIL E1: wo new succeeded with its CHECKLIST template missing"; exit 1; }
refused E1 wo /core/templates/workorders/WO-TEMPLATE-CHECKLIST.md
! ls -d "$WD"/WO-*-missing-tpl >/dev/null 2>&1 || { echo "FAIL E1: wo new left a half-made folder"; exit 1; }
# E1b: a template that is there but cannot be read is refused the same way, in both drivers
fresh; chmod 000 "$T/workorders/WO-TEMPLATE-CHECKLIST.md"; run $A/bin/wo new "Locked tpl" --size standard; chmod 644 "$T/workorders/WO-TEMPLATE-CHECKLIST.md"
refused E1b wo /core/templates/workorders/WO-TEMPLATE-CHECKLIST.md
! ls -d "$WD"/WO-*-locked-tpl >/dev/null 2>&1 || { echo "FAIL E1b: wo new left a half-made folder"; exit 1; }
chmod 000 "$T/bugs/BUG-TEMPLATE-ISSUE.md"; run $A/bin/bug new "Locked bug"; chmod 644 "$T/bugs/BUG-TEMPLATE-ISSUE.md"
refused E1b bug /core/templates/bugs/BUG-TEMPLATE-ISSUE.md
! ls -d "$BD"/BUG-*-locked-bug >/dev/null 2>&1 || { echo "FAIL E1b: bug new left a half-made folder"; exit 1; }
# E2: wo suite with its template missing refuses and writes no suite
fresh; $A/bin/wo new "s" --size small >/dev/null 2>&1 || { echo "FAIL setup: wo new failed"; exit 1; }; num="$(ls -d "$WD"/WO-*-s | sed 's#.*/WO-##; s#-s$##')"
rm "$T/testing/SUITE-TEMPLATE.sh"; run $A/bin/wo suite "$num"
refused E2 wo /core/templates/testing/SUITE-TEMPLATE.sh
! ls "$SU"/wo-"$num"-* >/dev/null 2>&1 || { echo "FAIL E2: wo suite wrote a suite with no template"; exit 1; }
# E3: wo integrate with its template missing refuses before it opens the work order
fresh; for x in a b; do $A/bin/wo new "$x" --size small >/dev/null 2>&1 || { echo "FAIL setup: wo new failed"; exit 1; }; done
na="$(ls -d "$WD"/WO-*-a | sed 's#.*/WO-##; s#-a$##')"; nb="$(ls -d "$WD"/WO-*-b | sed 's#.*/WO-##; s#-b$##')"
$A/bin/wo suite "$na" >/dev/null 2>&1 && $A/bin/wo suite "$nb" >/dev/null 2>&1 || { echo "FAIL setup: wo suite failed"; exit 1; }
rm "$T/testing/INTEGRATION-SUITE-TEMPLATE.sh"; run $A/bin/wo integrate "integ" --covers "$na,$nb"
refused E3 wo /core/templates/testing/INTEGRATION-SUITE-TEMPLATE.sh
! ls -d "$WD"/WO-*-integ >/dev/null 2>&1 || { echo "FAIL E3: wo integrate opened a work order with no suite template"; exit 1; }
! ls "$SU"/*integ* >/dev/null 2>&1 || { echo "FAIL E3: wo integrate wrote a suite with no template"; exit 1; }
# E4: wo verify with the verification template missing refuses and writes no VERIFICATION document
fresh; $A/bin/wo new "v" --size small >/dev/null 2>&1 || { echo "FAIL setup: wo new failed"; exit 1; }; num="$(ls -d "$WD"/WO-*-v | sed 's#.*/WO-##; s#-v$##')"
rm "$T/testing/TEST-TEMPLATE-VERIFICATION.md"; run $A/bin/wo verify "$num"
refused E4 wo /core/templates/testing/TEST-TEMPLATE-VERIFICATION.md
[ ! -e "$(ls -d "$WD"/WO-"$num"-v)/WO-$num-VERIFICATION.md" ] || { echo "FAIL E4: wo verify wrote a VERIFICATION document with no template"; exit 1; }
# E5: bug new with its template missing refuses and leaves no folder
fresh; rm "$T/bugs/BUG-TEMPLATE-ISSUE.md"; run $A/bin/bug new "Missing bug tpl"
refused E5 bug /core/templates/bugs/BUG-TEMPLATE-ISSUE.md
! ls -d "$BD"/BUG-*-missing-bug-tpl >/dev/null 2>&1 || { echo "FAIL E5: bug new left a half-made folder"; exit 1; }
# E6: bug verify with both verification templates missing refuses (render_v) and writes no VERIFICATION document
fresh; $A/bin/bug new "bv" >/dev/null 2>&1 || { echo "FAIL setup: bug new failed"; exit 1; }; bd="$(ls -d "$BD"/BUG-*-bv)"; bn="${bd##*/BUG-}"; bn="${bn%-bv}"
rm -f "$T/bugs/BUG-TEMPLATE-VERIFICATION.md" "$T/testing/TEST-TEMPLATE-VERIFICATION.md"; run $A/bin/bug verify "$bn"
refused E6 bug /core/templates/testing/TEST-TEMPLATE-VERIFICATION.md
[ ! -e "$bd/BUG-$bn-VERIFICATION.md" ] || { echo "FAIL E6: bug verify wrote a VERIFICATION document with no template"; exit 1; }
# E7: acp ci github with its template missing refuses and writes no workflow, so a later run is not "left alone"
fresh; git init -q . || { echo "FAIL setup: git init"; exit 1; }; rm "$T/ci/acp-check.yml"; run $A/bin/acp ci github
refused E7 acp /core/templates/ci/acp-check.yml
[ ! -e .github/workflows/acp-check.yml ] || { echo "FAIL E7: acp ci github wrote an empty workflow"; exit 1; }
# E8, E9: acp command and acp skill with an unreadable file refuse instead of printing nothing
fresh; c="$(ls "$A"/core/commands/*.md | head -1)"; chmod 000 "$c"; run $A/bin/acp command "$(basename "$c" .md)"; chmod 644 "$c"
refused E8 acp "/core/commands/$(basename "$c")"
s="$(ls -d "$A"/core/skills/*/ | head -1)"; s="${s%/}"; chmod 000 "$s/SKILL.md"; run $A/bin/acp skill "$(basename "$s")"; chmod 644 "$s/SKILL.md"
refused E9 acp "/core/skills/$(basename "$s")/SKILL.md"
# E10: acp intake with a step's suite unreadable refuses before it opens that step's work order
fresh; rm -rf "$WD"/WO-0001-* "$SU"/intake-01-*; before="$(ls -d "$WD"/WO-* | wc -l | tr -d ' ')"
i="$(ls "$T"/intake/intake-01-*.sh | head -1)"; chmod 000 "$i"; run $A/bin/acp intake; chmod 644 "$i"
refused E10 "acp intake" "/core/templates/intake/$(basename "$i")"
! ls "$SU"/intake-01-* >/dev/null 2>&1 || { echo "FAIL E10: acp intake wrote the step's suite with no template"; exit 1; }
[ "$(ls -d "$WD"/WO-* | wc -l | tr -d ' ')" -eq "$before" ] || { echo "FAIL E10: acp intake opened the step's work order before refusing"; exit 1; }
# E10b: acp intake whose wo new refuses (a work-order template missing) shows that refusal and its own line,
# exits 1, and leaves no half-made order (S265-1: under pipefail it ended with no word at all)
fresh; rm -rf "$WD"/WO-0001-* "$SU"/intake-01-*; before="$(ls -d "$WD"/WO-* | wc -l | tr -d ' ')"; rm "$T/workorders/WO-TEMPLATE-SPEC-ANALYSIS.md"
run $A/bin/acp intake
refused E10b wo /core/templates/workorders/WO-TEMPLATE-SPEC-ANALYSIS.md
printf '%s\n' "$err" | grep -qxF "acp intake: could not open step 01" || { echo "FAIL E10b: acp intake did not say which step it could not open: $err"; exit 1; }
[ "$(ls -d "$WD"/WO-* | wc -l | tr -d ' ')" -eq "$before" ] || { echo "FAIL E10b: a half-made order was left when wo new refused"; exit 1; }
# E11: with every template in place nothing changed: each command works and writes a file with content
fresh; git init -q . || { echo "FAIL setup: git init"; exit 1; }
$A/bin/wo new "whole" --size standard >/dev/null 2>&1 || { echo "FAIL E11: an ordinary wo new failed"; exit 1; }
w="$(ls -d "$WD"/WO-*-whole)"; num="${w##*/WO-}"; num="${num%-whole}"
[ -s "$w/WO-$num-CHECKLIST.md" ] || { echo "FAIL E11: an ordinary wo new wrote an empty CHECKLIST"; exit 1; }
$A/bin/wo suite "$num" >/dev/null 2>&1 && [ -s "$(ls "$SU"/wo-"$num"-* | head -1)" ] || { echo "FAIL E11: an ordinary wo suite failed or wrote nothing"; exit 1; }
$A/bin/bug new "whole bug" >/dev/null 2>&1 && [ -s "$(ls "$BD"/BUG-*-whole-bug/BUG-*-whole-bug.md | head -1)" ] || { echo "FAIL E11: an ordinary bug new failed or wrote nothing"; exit 1; }
$A/bin/acp ci github >/dev/null 2>&1 && [ -s .github/workflows/acp-check.yml ] || { echo "FAIL E11: an ordinary acp ci github failed or wrote nothing"; exit 1; }
o="$($A/bin/acp command "$(basename "$c" .md)" 2>/dev/null)" && printf '%s\n' "$o" | grep -qF -- "---" || { echo "FAIL E11: an ordinary acp command failed or printed no command"; exit 1; }
o="$($A/bin/acp skill "$(basename "$s")" 2>/dev/null)" && [ "$(printf '%s\n' "$o" | wc -l | tr -d ' ')" -gt 3 ] || { echo "FAIL E11: an ordinary acp skill failed or printed no skill"; exit 1; }
exit 0
