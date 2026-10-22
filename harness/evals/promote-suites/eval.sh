#!/usr/bin/env bash
# promote-suites: wo promote carries only the suites the record's **Suite:** lines name, and only a regular file
# directly in the project's suites folder; a path written into a record cannot copy any other file into
# a playbook.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
"$PIPELINE_ROOT/bin/new-project" p --name P >/dev/null 2>&1; cd p || die "new-project failed"
git config user.email e@x; git config user.name e
W=./.aicodepipeline/bin/wo; SU=Workspace/Testing/suites
n="$($W new "Carry suites" --size small --area docs | grep -o 'WO-[0-9]*' | head -1)"; n="${n#WO-}"
[ -n "$n" ] || die "wo new opened no work order"
$W suite "$n" >/dev/null; s="$(ls $SU/wo-"$n"-*.sh)"
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > "$s"
# a first run whose log ends without a newline, so its closing fence lands on the log's last line
printf '#!/usr/bin/env bash\nprintf "1 passed, 0 failed"\n' > "$SU/first.sh"
$W verify "$n" --run "$SU/first.sh" >/dev/null 2>&1 || die "the first suite did not verify"
$W verify "$n" --run "$s" >/dev/null 2>&1 || die "the suite did not verify"
v="$(ls Workspace/Docs/WorkOrders/WO-"$n"-*/WO-"$n"-VERIFICATION.md)"
# what a hand-edited or received record could name
printf 'SECRET-225-A\n' > "$EVAL_TMP/secret.txt"
printf 'SECRET-225-B\n' > notes.txt
printf 'SECRET-225-D\n' > "$EVAL_TMP/linked.txt"
ln -s "$EVAL_TMP/linked.txt" "$SU/link.sh"
printf 'SECRET-225-C\n' > "$SU/cmdonly.sh"
mkdir -p "$EVAL_TMP/outside/sub"; printf 'SECRET-225-E\n' > "$EVAL_TMP/outside/key"; ln -s "$EVAL_TMP/outside/sub" "$SU/L"
printf 'inside\n' > "$SU/key"   # a same-named file in the suites folder must not stand in for the one named
printf 'SECRET-225-G\n' > "$SU/fenced.sh"
{ printf -- '- **Command:** `bash %s`\n' "$EVAL_TMP/secret.txt"
  printf -- '- **Suite:** `%s` (0000)\n' "$EVAL_TMP/secret.txt"
  printf -- '- **Suite:** `%s/link.sh` (0000)\n' "$SU"
  printf -- '- **Suite:** `%s/../../../notes.txt` (0000)\n' "$SU"
  printf -- '- **Command:** `bash %s/cmdonly.sh`\n' "$SU"
  printf -- '- **Suite:** `%s/L/../key` (0000)\n' "$SU"
  printf -- '- **Suite:** `%s/../suites/%s` (0000)\n' "$SU" "$(basename "$s")"
  printf -- '- **Suite:** `Workspace/%s` (0000)\n' "$(basename "$s")"
  printf -- '```\n- **Suite:** `%s/fenced.sh` (0000)\n```\n' "$SU"; } >> "$v"
out="$($W promote "$n" --allow-unsanitized --allow-placeholders 2>&1)" || die "wo promote failed" "$out"
pb=.aicodepipeline/playbooks/p
[ -d "$pb/workorders" ] || die "wo promote wrote no playbook folder" "$out"
grep -rqF 'SECRET-225-A' "$pb" && die "FAIL P1: wo promote copied a file from outside the project into the playbook"
grep -rqF 'SECRET-225-B' "$pb" && die "FAIL P2: wo promote carried a path that leaves the suites folder"
grep -rqF 'SECRET-225-D' "$pb" && die "FAIL P3: wo promote carried a link in the suites folder"
grep -rqF 'SECRET-225-E' "$pb" && die "FAIL P3: wo promote followed a link out of the suites folder"
[ -e "$(ls -d "$pb"/workorders/WO-"$n"-*)/suite/key" ] && die "FAIL P3: wo promote carried a suites-folder file in place of the one a link led to"
grep -rqF 'SECRET-225-C' "$pb" && die "FAIL P4: wo promote carried a suite no Suite line names"
grep -rqF 'SECRET-225-G' "$pb" && die "FAIL P4: wo promote carried a suite named only inside a quoted log"
[ -f "$(ls -d "$pb"/workorders/WO-"$n"-*)/suite/$(basename "$s")" ] || die "FAIL P5: the suite that produced the evidence did not travel" "$out"
grep -qF "suite/$(basename "$s")" "$pb/catalog/WO-$n.md" || die "FAIL P5: the catalog does not point at the carried suite"
[ "$(grep -oF "suite/$(basename "$s")" "$pb/catalog/WO-$n.md" | wc -l | tr -d ' ')" = 1 ] \
  || die "FAIL P5: one suite named two ways is listed more than once" "$(cat "$pb/catalog/WO-$n.md")"
for x in "$EVAL_TMP/secret.txt" "$SU/link.sh" "$SU/../../../notes.txt" "$SU/L/../key" "Workspace/$(basename "$s")"; do
  printf '%s\n' "$out" | grep -qxF "promote: not carried: $x (not a regular file in Workspace/Testing/suites)" \
    || die "FAIL P6: wo promote did not name a suite it left behind" "$out"
done
# P7: a suites folder that is itself a link out of the project carries nothing
mkdir -p "$EVAL_TMP/elsewhere"; printf 'SECRET-225-F\n' > "$EVAL_TMP/elsewhere/id.sh"
mv "$SU" "$EVAL_TMP/suites-away" && ln -s "$EVAL_TMP/elsewhere" "$SU" || die "the eval could not link the suites folder"
printf -- '- **Suite:** `%s/id.sh` (0000)\n' "$SU" >> "$v"
out="$($W promote "$n" --allow-unsanitized --allow-placeholders 2>&1)" || die "the second wo promote failed" "$out"
grep -rqF 'SECRET-225-F' "$pb" && die "FAIL P7: wo promote carried a suite from a suites folder linked out of the project"
printf '%s\n' "$out" | grep -qxF "promote: not carried: $SU/id.sh (not a regular file in Workspace/Testing/suites)" \
  || die "FAIL P7: wo promote did not name the suite it left behind" "$out"
echo "promote-suites: all checks passed"
exit 0
