#!/usr/bin/env bash
# playbook-confined: wo promote and bug promote take a playbook name, one folder directly in the playbooks folder;
# a name that is a path (../x, a/b) or starts with '.' or '-' is refused before anything is removed or
# copied, so promote can never delete or write outside the playbooks folder.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1; cd p || die "new-project failed"
W=./.aicodepipeline/bin/wo; B=./.aicodepipeline/bin/bug
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > ok.sh
n="$($W new "Confined" --size small --area docs | grep -o 'WO-[0-9]*' | head -1)"; n="${n#WO-}"
[ -n "$n" ] || die "wo new opened no work order"
$W verify "$n" --run ./ok.sh >/dev/null 2>&1 || die "the work order did not verify"
wb="$(basename "$(ls -d Workspace/Docs/WorkOrders/WO-"$n"-*)")"
# what promote's rm -rf would reach through ../../../victim from the playbooks folder
mkdir -p "$EVAL_TMP/victim/workorders/$wb"; printf 'keep\n' > "$EVAL_TMP/victim/workorders/$wb/keep.txt"
rc=0; out="$($W promote "$n" --playbook ../../../victim --allow-placeholders 2>&1)" || rc=$?
[ -f "$EVAL_TMP/victim/workorders/$wb/keep.txt" ] || die "FAIL Q1: wo promote --playbook ../../../victim deleted a folder outside the playbooks folder"
[ "$rc" -ne 0 ] || die "FAIL Q1: wo promote took a playbook name that is a path" "$out"
printf '%s\n' "$out" | grep -qF "refusing to promote WO-$n: '../../../victim' is not a playbook name" || die "FAIL Q1: wo promote did not say why it refused" "$out"
[ -e "$EVAL_TMP/victim/catalog" ] && die "FAIL Q1: wo promote wrote a catalog outside the playbooks folder"
# Q2: every other unsafe name is refused, and writes nothing
for x in . .. .hidden -x a/b "a b" 'a$b' "$EVAL_TMP/abs"; do
  rc=0; out="$($W promote "$n" --playbook "$x" --allow-placeholders 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || die "FAIL Q2: wo promote took the playbook name '$x'" "$out"
  printf '%s\n' "$out" | grep -qF "is not a playbook name" || die "FAIL Q2: wo promote refused '$x' without saying why" "$out"
done
# Q3: a good name still works
out="$($W promote "$n" --playbook team-1.x_y --allow-placeholders 2>&1)" || die "FAIL Q3: wo promote refused a good playbook name" "$out"
[ -d ".aicodepipeline/playbooks/team-1.x_y/workorders/$wb" ] || die "FAIL Q3: the promoted work order is not in the named playbook" "$out"
# Q4: bug promote is confined the same way
b="$($B new "Confined bug" --category api | grep -o 'BUG-[0-9]*' | head -1)"; b="${b#BUG-}"
[ -n "$b" ] || die "bug new opened no bug"
$B verify "$b" --run ./ok.sh >/dev/null 2>&1 || die "the bug did not verify"
bb="$(basename "$(ls -d Workspace/Docs/Bugs/BUG-"$b"-*)")"
mkdir -p "$EVAL_TMP/victim2/bugs/$bb"; printf 'keep\n' > "$EVAL_TMP/victim2/bugs/$bb/keep.txt"
rc=0; out="$($B promote "$b" --playbook ../../../victim2 2>&1)" || rc=$?
[ -f "$EVAL_TMP/victim2/bugs/$bb/keep.txt" ] || die "FAIL Q4: bug promote --playbook ../../../victim2 deleted a folder outside the playbooks folder"
[ "$rc" -ne 0 ] || die "FAIL Q4: bug promote took a playbook name that is a path" "$out"
printf '%s\n' "$out" | grep -qF "refusing to promote BUG-$b: '../../../victim2' is not a playbook name" || die "FAIL Q4: bug promote did not say why it refused" "$out"
echo "playbook-confined: all checks passed"
exit 0
