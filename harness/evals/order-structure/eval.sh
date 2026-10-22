#!/usr/bin/env bash
# Every work-order and bug folder follows one structure: only order folders under the work-order and bug
# folders, each holding only its own documents, its driver files, its verification logs and one artifacts/
# folder, which the drivers make and the work-order and bug folders' own .gitignore keeps out of git (a file git
# sees there anyway fails under every profile); a suite named for an order needs that order. A stray is a warning,
# and a failure under the strict profile; acp doctor and acp check say so, and promote leaves artifacts/ out of a
# playbook.
set -uo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
export HOME="$EVAL_TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$EVAL_TMP"; mkdir -p "$HOME"
unset ACP_STRICT ACP_HOOK_PROFILE
git config --global user.name t && git config --global user.email t@example.com || die "the eval could not set a git identity"
has() { case "$out" in *"$1"*) return 0;; esac; return 1; }
line() { case $'\n'"$out" in *$'\n'"$1"*) return 0;; esac; return 1; }   # a line of the output starts with $1
m() { mkdir -p "$(dirname "$1")" && printf '%s\n' "${2:-x}" > "$1"; }
L="$PIPELINE_ROOT/core/hooks/layout.py"
lay() { rc=0; out="$(python3 "$L" --root "$1" 2>&1)" || rc=$?; }
lays() { rc=0; out="$(ACP_HOOK_PROFILE=strict python3 "$L" --root "$1" 2>&1)" || rc=$?; }
# stray <finding> <FAIL line>: a warning under the default profile, a failure under strict
stray() {
  lay "$P"; { [ "$rc" -eq 0 ] && line "warn structure $1"; } || die "$2" "default profile: exit $rc" "$out"
  lays "$P"; { [ "$rc" -eq 1 ] && line "structure $1"; } || die "$2" "strict profile: exit $rc" "$out"
}
W0=Workspace/Docs/WorkOrders; B0=Workspace/Docs/Bugs; S0=Workspace/Testing/suites
# a project in the default layout (code at the root), one small and complete order, one bug, their suites
P="$EVAL_TMP/p"; mkdir -p "$P" && git -C "$P" init -q && printf 'export WORKSPACE_DIR="Workspace"\n' > "$P/pipeline.config.sh" \
  && m "$P/src/a.js" && m "$P/$W0/WO-0001-first/.wo-meta" "size=small" && m "$P/$W0/WO-0001-first/.wo-manifest" \
  && m "$P/$W0/WO-0001-first/WO-0001-SPEC.md" && m "$P/$W0/WO-0001-first/WO-0001-DRY-RUN.md" && m "$P/$W0/WO-0001-first/WO-0001-REVIEW-ROUND-2.md" \
  && m "$P/$W0/WO-0001-first/WO-0001-VERIFICATION-20261021-101010-123.log" && m "$P/$W0/.gitignore" '/*/artifacts/' \
  && m "$P/$B0/BUG-0001-crash/.bug-meta" "status=open" && m "$P/$B0/BUG-0001-crash/.bug-manifest" && m "$P/$B0/BUG-0001-crash/BUG-0001-crash.md" \
  && m "$P/$B0/.gitignore" '/*/artifacts/' \
  && m "$P/$S0/wo-0001-first.sh" && m "$P/$S0/bug-0001-crash.sh" && m "$P/$S0/intake-01-scan.sh" && m "$P/$S0/lib/helpers.sh" \
  && m "$P/.claude/agents/a.md" && m "$P/.claude/skills/s/SKILL.md" \
  && git -C "$P" add -A && git -C "$P" commit -q -m start || die "the eval could not build a project"
# C0: a project whose orders follow the structure has nothing to say, under either profile
lay "$P"; { [ "$rc" -eq 0 ] && ! has "structure"; } || die "FAIL C0: a project whose orders follow the structure was reported" "exit $rc" "$out"
lays "$P"; { [ "$rc" -eq 0 ] && ! has "structure"; } || die "FAIL C0: under strict, a project whose orders follow the structure was reported" "exit $rc" "$out"

# S1-S5: what an order folder may not hold, and what may not sit among them: strays
m "$P/$W0/notes.md"
stray "$W0/notes.md: a loose file among the WO folders; move it into its order's folder" "FAIL S1: a loose file among the work orders was not named"
rm "$P/$W0/notes.md"
for f in "WO-12-short/x.md" "WO-0003--double/x.md" "drafts/x.md"; do
  m "$P/$W0/$f"; d="${f%%/*}"
  stray "$W0/$d: not a WO folder name" "FAIL S2: $d was not refused as an order folder name"
  rm -r "${P:?}/$W0/$d"
done
m "$P/$W0/WO-0001-first/WO-0002-SPEC.md"
stray "$W0/WO-0001-first/WO-0002-SPEC.md: a document of WO-0002 in WO-0001's folder; move it into WO-0002's folder" "FAIL S3: a document of another order was not named"
rm "$P/$W0/WO-0001-first/WO-0002-SPEC.md"
for f in notes.txt README.md WO-0001-CLOSEOUT.keep .gitignore; do
  m "$P/$W0/WO-0001-first/$f"
  stray "$W0/WO-0001-first/$f: not one of WO-0001's files" "FAIL S4: $f in an order folder was not named"
  has "move it into WO-0001-first/artifacts/ or delete it" || die "FAIL S4: the finding for $f did not say where it goes" "$out"
  rm "$P/$W0/WO-0001-first/$f"
done
m "$P/$W0/WO-0001-first/drafts/a.md"
stray "$W0/WO-0001-first/drafts: a subfolder other than artifacts/" "FAIL S5: a subfolder was not named"
rm -r "${P:?}/$W0/WO-0001-first/drafts"
# J1: editor and system files are nobody's work and never a stray
for f in "$W0/.DS_Store" "$W0/notes.md~" "$W0/WO-0001-first/.WO-0001-SPEC.md.swp" "$W0/WO-0001-first/#scratch#" "$B0/BUG-0001-crash/.DS_Store"; do
  m "$P/$f"; lays "$P"; { [ "$rc" -eq 0 ] && ! has "structure"; } || die "FAIL J1: an editor or system file ($f) was named" "exit $rc" "$out"; rm "$P/$f"
done
# A1: artifacts/ is the order's own: the work-order folder's .gitignore keeps it out of git and it is not judged;
# a file git sees there is a leak, a failure under every profile, which says how to restore the rule
m "$P/$W0/WO-0001-first/artifacts/run.log"
lay "$P"; { [ "$rc" -eq 0 ] && ! has "structure" && ! line "artifacts "; } || die "FAIL A1: an artifacts/ folder git ignores was judged" "exit $rc" "$out"
mv "$P/$W0/.gitignore" "$EVAL_TMP/wo-gitignore.keep"; lay "$P"
{ [ "$rc" -eq 1 ] && line "artifacts $W0/WO-0001-first/artifacts: working files git would commit" && has "acp install"; } \
  || die "FAIL A1: a file git would commit under artifacts/ was not a failure under the default profile" "exit $rc" "$out"
mv "$EVAL_TMP/wo-gitignore.keep" "$P/$W0/.gitignore"; rm "${P:?}/$W0/WO-0001-first/artifacts/run.log"
# W1-W3: worth a word, never a failure: a README beside the orders, missing documents, a status the CLOSEOUT contradicts
m "$P/$W0/README.md"; lays "$P"
{ [ "$rc" -eq 0 ] && line "warn structure $W0/README.md: a README beside the WO folders"; } || die "FAIL W1: a README beside the orders was not a warning" "exit $rc" "$out"
rm "$P/$W0/README.md"
m "$P/$W0/WO-0002-second/.wo-meta" "size=standard" && m "$P/$W0/WO-0002-second/WO-0002-SPEC.md"; lays "$P"
{ [ "$rc" -eq 0 ] && line "warn structure $W0/WO-0002-second: WO-0002 (standard) lacks CHECKLIST, TASK-BREAKDOWN, Prompt, REVIEW"; } \
  || die "FAIL W2: documents an order's size requires were not warned of" "exit $rc" "$out"
rm -r "${P:?}/$W0/WO-0002-second"
m "$P/$B0/BUG-0001-crash/BUG-0001-crash-CLOSEOUT.md"; lay "$P"
{ [ "$rc" -eq 0 ] && line "warn structure $B0/BUG-0001-crash: BUG-0001 has a CLOSEOUT but its meta says status=open"; } \
  || die "FAIL W3: a CLOSEOUT beside status=open was not warned of" "exit $rc" "$out"
m "$P/$B0/BUG-0001-crash/.bug-meta" "status=in-progress"; lay "$P"
{ [ "$rc" -eq 0 ] && ! has "structure"; } || die "FAIL W3: a CLOSEOUT beside the in-progress status 1.4 left behind was warned of" "exit $rc" "$out"
rm "$P/$B0/BUG-0001-crash/BUG-0001-crash-CLOSEOUT.md"; m "$P/$B0/BUG-0001-crash/.bug-meta" "status=closed"; lay "$P"
{ [ "$rc" -eq 0 ] && line "warn structure $B0/BUG-0001-crash: BUG-0001's meta says status=closed but it has no CLOSEOUT"; } \
  || die "FAIL W3: status=closed without a CLOSEOUT was not warned of" "exit $rc" "$out"
m "$P/$B0/BUG-0001-crash/.bug-meta" "status=open"
# B1: bugs follow the same structure, with their own documents
for f in "BUG-0002--x/a.md" "BUG-0001-crash/fix.patch" "BUG-0001-crash/WO-0001-SPEC.md"; do
  m "$P/$B0/$f"; lays "$P"; { [ "$rc" -eq 1 ] && line "structure $B0/"; } || die "FAIL B1: $f among the bugs was not a stray" "exit $rc" "$out"; rm "$P/$B0/$f"
done
rmdir "$P/$B0/BUG-0002--x"
lays "$P"; [ "$rc" -eq 0 ] || die "FAIL B1: the bug fixture did not come back clean" "exit $rc" "$out"
# U1: a suite named for an order needs that order, under any profile; any other suite is the project's own
m "$P/$S0/wo-0009-gone.sh"; lay "$P"
{ [ "$rc" -eq 1 ] && line "structure $S0/wo-0009-gone.sh: a suite for WO-0009, which has no folder"; } \
  || die "FAIL U1: a suite whose order has no folder was not a failure" "exit $rc" "$out"
rm "$P/$S0/wo-0009-gone.sh"
for f in rate-limit.sh users-crud.sh notes.txt fixtures/users.json; do
  m "$P/$S0/$f"; lays "$P"; { [ "$rc" -eq 0 ] && ! has "structure"; } || die "FAIL U1: the suite folder's own $f was named" "exit $rc" "$out"; rm "$P/$S0/$f"
done
# T1: a TESTING_DIR written with a variable leaves the suites unjudged, and the rest of the check running
cp "$P/pipeline.config.sh" "$EVAL_TMP/config.keep" && printf 'export TESTING_DIR="$WORKSPACE_DIR/Testing"\n' >> "$P/pipeline.config.sh"
m "$P/$S0/wo-0009-gone.sh" && m "$P/$W0/notes.md"; lays "$P"
{ [ "$rc" -eq 1 ] && line "structure $W0/notes.md" && ! has "wo-0009-gone" && has "the suites are not judged"; } \
  || die "FAIL T1: a TESTING_DIR written with a variable switched off more than the suites" "exit $rc" "$out"
cp "$EVAL_TMP/config.keep" "$P/pipeline.config.sh" && rm "$P/$S0/wo-0009-gone.sh" "$P/$W0/notes.md"
# H1: more than a handful of strays points at acp migrate, which files them
for i in 1 2 3 4 5 6; do m "$P/$W0/stray-$i.md"; done; lay "$P"
{ [ "$rc" -eq 0 ] && line "warn structure $W0: 6 strays in the work-order and bug folders; acp migrate plan files them"; } \
  || die "FAIL H1: six strays did not point at acp migrate" "exit $rc" "$out"
rm "$P/$W0"/stray-*.md

# D1: acp doctor shows a stray as WARN, and as FAIL under strict; a README as WARN; never "nothing out of place" beside them
m "$P/$W0/notes.md" && m "$P/$W0/README.md"
rc=0; out="$("$PIPELINE_ROOT/bin/acp" doctor "$P" 2>&1)" || rc=$?
{ printf '%s\n' "$out" | grep 'layout: structure .*notes.md' | grep -q WARN && printf '%s\n' "$out" | grep 'layout: structure .*README.md' | grep -q WARN \
  && ! has "nothing out of place"; } || die "FAIL D1: acp doctor did not show a stray and a README as WARN alone" "$out"
rc=0; out="$(ACP_HOOK_PROFILE=strict "$PIPELINE_ROOT/bin/acp" doctor "$P" 2>&1)" || rc=$?
{ printf '%s\n' "$out" | grep 'layout: structure .*notes.md' | grep -q FAIL && printf '%s\n' "$out" | grep 'layout: structure .*README.md' | grep -q WARN; } \
  || die "FAIL D1: under strict acp doctor did not show the stray as FAIL and the README as WARN" "$out"
rm "$P/$W0/notes.md" "$P/$W0/README.md"
# R1: the required-document table is bin/wo's own (both read as text, nothing run)
python3 -I - "$PIPELINE_ROOT/bin/wo" "$L" <<'PY' || die "FAIL R1: layout.py's required documents differ from bin/wo's required_docs()"
import ast, re, sys
wo = open(sys.argv[1]).read()
block = wo[wo.index("required_docs() {"):]; block = block[:block.index("\n}")]
table = {k: v.split() for k, v in re.findall(r'^\s*(\w+|\*)\)\s+echo "([^"]*)";;', block, re.M)}
table["standard"] = table.pop("*")
tree = ast.parse(open(sys.argv[2]).read())
mine = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign) and [getattr(t, "id", "") for t in n.targets] == ["REQUIRED_DOCS"])
sys.exit(0 if mine == table else 1)
PY

# K1-K3: at commit, a staged stray is a note under standard and blocks under strict (the profile or --strict); a
# staged warning never blocks; a working file forced in from artifacts/ blocks under every profile
chk() { rc=0; out="$(cd "$P" && python3 "$PIPELINE_ROOT/core/hooks/check.py" --root "$P" --staged "$@" 2>&1)" || rc=$?; }
m "$P/$W0/stray.md" && git -C "$P" add "$W0/stray.md"
chk; { [ "$rc" -eq 0 ] && has "layout: structure $W0/stray.md"; } || die "FAIL K1: under standard a staged stray was not a note" "exit $rc" "$out"
rc=0; out="$(cd "$P" && ACP_HOOK_PROFILE=strict python3 "$PIPELINE_ROOT/core/hooks/check.py" --root "$P" --staged 2>&1)" || rc=$?
{ [ "$rc" -eq 2 ] && has "layout: structure $W0/stray.md"; } || die "FAIL K1: under strict a staged stray did not block" "exit $rc" "$out"
chk --strict; { [ "$rc" -eq 2 ] && has "layout: structure $W0/stray.md"; } || die "FAIL K2: check --strict did not block a staged stray" "exit $rc" "$out"
git -C "$P" rm -q --cached "$W0/stray.md"; rm "$P/$W0/stray.md"
m "$P/$W0/README.md" && git -C "$P" add "$W0/README.md"
chk --strict; { [ "$rc" -eq 0 ] && has "layout: structure $W0/README.md"; } || die "FAIL K1: under strict a staged warning blocked or was not said" "exit $rc" "$out"
git -C "$P" rm -q --cached "$W0/README.md"; rm "$P/$W0/README.md"
m "$P/$W0/WO-0001-first/artifacts/run.log" && git -C "$P" add -f "$W0/WO-0001-first/artifacts/run.log"
chk; { [ "$rc" -eq 2 ] && has "layout: artifacts $W0/WO-0001-first/artifacts"; } || die "FAIL K3: under standard a working file forced in from artifacts/ did not block" "exit $rc" "$out"
git -C "$P" rm -q --cached "$W0/WO-0001-first/artifacts/run.log"; rm "${P:?}/$W0/WO-0001-first/artifacts/run.log"

# G1-G13: the work-order and bug folders' own .gitignore keeps every order's artifacts/ out of git, in the checkout,
# an order's worktree and a fresh clone; install and the drivers keep that file; the drivers make every order's
# artifacts/; close writes status=closed; a title with no letter a folder can hold is "untitled"; adopt in place files
# its record (git mv when tracked) and says what else it keeps
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" g --name G >/dev/null 2>&1 || die "the eval could not install a project with git"
G="$EVAL_TMP/g"; cd "$G" || exit 1
W=./.aicodepipeline/bin/wo; B=./.aicodepipeline/bin/bug
num() { grep -o "$1-[0-9]*" | head -1 | sed "s/^$1-//"; }
rule() { [ "$(cat "$1/.gitignore" 2>/dev/null)" = '/*/artifacts/' ]; }
art() { [ -d "$1/artifacts" ] && [ ! -L "$1/artifacts" ]; }
{ rule "$W0" && rule "$B0"; } || die "FAIL G10: new-project did not give the work-order and bug folders a .gitignore of /*/artifacts/" "$(cat "$W0/.gitignore" "$B0/.gitignore" 2>&1)"
for s in trivial small standard large; do
  n="$($W new "Size $s" --size "$s" | num WO)"; art "$(ls -d $W0/WO-"$n"-*)" || die "FAIL G1: wo new --size $s made no artifacts/"
done
n="$($B new "A bug" --category api | num BUG)"; art "$(ls -d $B0/BUG-"$n"-*)" || die "FAIL G2: bug new made no artifacts/"
m "$EVAL_TMP/old-wo.md" "# An old order" && m "$EVAL_TMP/old-bug.md" "# An old bug"
$W adopt "$EVAL_TMP/old-wo.md" --number 300 >/dev/null && art "$(ls -d $W0/WO-0300-*)" || die "FAIL G3: wo adopt made no artifacts/"
$B adopt "$EVAL_TMP/old-bug.md" --number 1300 --category api >/dev/null && art "$(ls -d $B0/BUG-1300-*)" || die "FAIL G3: bug adopt made no artifacts/"
# G4: adopt in place files the record it is given under the order's document name and names only what else it keeps
m "$W0/WO-0301-kept/notes.md" "# Kept" && m "$W0/WO-0301-kept/run.out"
out="$($W adopt "$W0/WO-0301-kept/notes.md" --number 301 --size trivial --dry-run 2>&1)"
{ has "would file  notes.md as WO-0301-kept.md" && has "WO-0301-kept/run.out: not one of WO-0301's files" && ! has "WO-0301-kept/notes.md:" \
  && [ -f "$W0/WO-0301-kept/notes.md" ] && [ ! -f "$W0/WO-0301-kept/.wo-meta" ]; } \
  || die "FAIL G4: wo adopt --dry-run did not say it files the record and keeps the rest, or wrote something" "$out"
out="$($W adopt "$W0/WO-0301-kept/notes.md" --number 301 --size trivial 2>&1)"
{ has "filed notes.md as WO-0301-kept.md" && [ -f "$W0/WO-0301-kept/WO-0301-kept.md" ] && [ ! -e "$W0/WO-0301-kept/notes.md" ] \
  && has "WO-0301-kept/run.out: not one of WO-0301's files" && ! has "WO-0301-kept/notes.md:" && art "$W0/WO-0301-kept"; } \
  || die "FAIL G4: wo adopt in place did not file its record, name what it keeps, and make artifacts/" "$out"
m "$B0/BUG-1301-kept/trace.md" "# Kept" && m "$B0/BUG-1301-kept/trace.txt" && git add "$B0/BUG-1301-kept/trace.md" && git commit -q -m trace >/dev/null 2>&1 \
  || die "the eval could not commit a bug record"
out="$($B adopt "$B0/BUG-1301-kept/trace.md" --number 1301 --category api 2>&1)"
{ has "filed trace.md as BUG-1301-kept.md" && [ "$(git ls-files -- "$B0/BUG-1301-kept")" = "$B0/BUG-1301-kept/BUG-1301-kept.md" ] \
  && has "BUG-1301-kept/trace.txt: not one of BUG-1301's files" && art "$B0/BUG-1301-kept"; } \
  || die "FAIL G4: bug adopt in place did not git mv its tracked record, or did not name what it keeps" "$out" "$(git ls-files -- "$B0/BUG-1301-kept")"
m "$W0/WO-0302-taken/notes.md" "# Taken" && m "$W0/WO-0302-taken/WO-0302-SPEC.md"
rc=0; out="$($W adopt "$W0/WO-0302-taken/notes.md" --number 302 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && has "which is taken" && [ -f "$W0/WO-0302-taken/notes.md" ] && [ ! -f "$W0/WO-0302-taken/.wo-meta" ]; } \
  || die "FAIL G4: wo adopt in place filed its record over a document already there, or wrote something" "exit $rc" "$out"
rm -r "${G:?}/$W0/WO-0302-taken"; rm "${G:?}/$W0/WO-0301-kept/run.out" "${G:?}/$B0/BUG-1301-kept/trace.txt"
n="$($W new "日本語" --size small | num WO)"; [ -d "$W0/WO-$n-untitled" ] || die "FAIL G7: wo new with a title of no letter a folder can hold did not make WO-$n-untitled" "$(ls $W0)"
n="$($B new "日本語" --category api | num BUG)"; [ -d "$B0/BUG-$n-untitled" ] || die "FAIL G7: bug new with such a title did not make BUG-$n-untitled" "$(ls $B0)"
# G11: wo new and bug new make a missing folder .gitignore again; wo new refuses one that is a link, making nothing
rm "${G:?}/$W0/.gitignore"; $W new "Again" --size small >/dev/null 2>&1 && rule "$W0" || die "FAIL G11: wo new did not make the work-order folder's .gitignore again"
rm "${G:?}/$B0/.gitignore"; $B new "Again" --category api >/dev/null 2>&1 && rule "$B0" || die "FAIL G11: bug new did not make the bug folder's .gitignore again"
mv "$W0/.gitignore" "$EVAL_TMP/wo-gi" && ln -s "$EVAL_TMP/wo-gi" "$W0/.gitignore" || die "the eval could not link the .gitignore"
before="$(ls "$W0" | wc -l)"; rc=0; out="$($W new "Linked" --size small 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && has "is a link" && [ "$(ls "$W0" | wc -l)" = "$before" ]; } || die "FAIL G11: wo new went ahead with the folder's .gitignore a link" "exit $rc" "$out"
rm "${G:?}/$W0/.gitignore" && mv "$EVAL_TMP/wo-gi" "$W0/.gitignore"
# G5, G9: wo start makes artifacts/; a file there stays out of git in the checkout, the order's worktree and a clone
printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh && chmod +x ok.sh
n="$($W new "Start then close" --size small | num WO)"; D="$(ls -d $W0/WO-"$n"-*)"; rmdir "$D/artifacts"
git add -A >/dev/null && git commit -q -m orders >/dev/null 2>&1 || die "the eval could not commit the orders"
$W start "$n" >/dev/null 2>&1 && art "$D" || die "FAIL G5: wo start did not make the order's artifacts/"
m "$D/artifacts/by-hand.txt" && [ -z "$(git status --porcelain -- "$D/artifacts")" ] || die "FAIL G9: git sees a file put in artifacts/" "$(git status --porcelain)"
WT="$(sed -n 's/^worktree=//p' "$D/.wo-meta")"; case "$WT" in /*) ;; *) WT="$G/$WT";; esac
m "$WT/$D/artifacts/in-worktree.txt" && git -C "$WT" add -A && [ -z "$(git -C "$WT" diff --cached --name-only)" ] \
  || die "FAIL G9: in the order's worktree, git add -A staged a file in artifacts/" "$(git -C "$WT" diff --cached --name-only)"
rm "${WT:?}/${D:?}/artifacts/in-worktree.txt"
git clone -q "$G" "$EVAL_TMP/clone" && m "$EVAL_TMP/clone/$D/artifacts/in-clone.txt" && git -C "$EVAL_TMP/clone" add -A \
  && [ -z "$(git -C "$EVAL_TMP/clone" diff --cached --name-only)" ] || die "FAIL G9: in a fresh clone, git add -A staged a file in artifacts/"
$W verify "$n" --run ./ok.sh >/dev/null 2>&1 && ALLOW_PLACEHOLDERS=1 $W close "$n" >/dev/null 2>&1 || die "the eval could not close WO-$n"
grep -qx 'status=closed' "$D/.wo-meta" || die "FAIL G6: wo close left the status at $(grep '^status=' "$D/.wo-meta")"
b="$($B new "Close me" --category api | num BUG)"
$B verify "$b" --run ./ok.sh >/dev/null 2>&1 && ALLOW_PLACEHOLDERS=1 $B close "$b" >/dev/null 2>&1 || die "the eval could not close BUG-$b"
grep -qx 'status=closed' "$(ls -d $B0/BUG-"$b"-*)/.bug-meta" || die "FAIL G6: bug close did not write status=closed"
git add -A >/dev/null 2>&1; lays "$G"
{ [ "$rc" -eq 0 ] && ! has "structure" && ! line "artifacts "; } || die "FAIL G8: what the drivers made (every size, adopt, start then close) was named" "exit $rc" "$out"
for g in '*.swp' '*~' '\#*#' '.DS_Store'; do grep -qxF "$g" .gitignore || die "FAIL G9: the project's .gitignore does not hold $g"; done
# G12: with the work-order folder's rule gone, acp doctor fails the leak and names acp install, which restores the rule
git rm -q "$W0/.gitignore" && git commit -q -m gone >/dev/null 2>&1 || die "the eval could not remove the rule"
rc=0; out="$(./.aicodepipeline/bin/acp doctor . 2>&1)" || rc=$?
{ printf '%s\n' "$out" | grep "layout: artifacts $D/artifacts" | grep -q FAIL && has "acp install"; } || die "FAIL G12: acp doctor did not fail the leak and name acp install" "$out"
"$PIPELINE_ROOT/bin/install.sh" "$G" >/dev/null 2>&1 && rule "$W0" || die "FAIL G12: acp install did not restore the work-order folder's .gitignore"
# G13: install keeps the rule beside a folder .gitignore's own lines (CRLF kept), writes nothing under --dry-run,
# and refuses a marker without its pair, writing nothing
printf '*.tmp\r\n' > "$B0/.gitignore"
out="$("$PIPELINE_ROOT/bin/install.sh" "$G" --dry-run 2>&1)"; { has "$B0/.gitignore: rule added" && [ "$(cat "$B0/.gitignore")" = "$(printf '*.tmp\r')" ]; } \
  || die "FAIL G13: install --dry-run did not say it would add the rule, or wrote it" "$out"
"$PIPELINE_ROOT/bin/install.sh" "$G" >/dev/null 2>&1 || die "FAIL G13: install failed on a folder .gitignore with lines of its own"
{ grep -q '^\*\.tmp' "$B0/.gitignore" && grep -qxF "$(printf '/*/artifacts/\r')" "$B0/.gitignore" && [ "$(grep -c "$(printf '\r$')" "$B0/.gitignore")" = "$(wc -l < "$B0/.gitignore" | tr -d ' ')" ]; } \
  || die "FAIL G13: install did not add the rule beside the file's own lines, CRLF kept" "$(od -c "$B0/.gitignore" | head -8)"
printf '# >>> AICodePipeline: order working files (the pipeline keeps this block) >>>\n*.tmp\n' > "$B0/.gitignore"; cp "$B0/.gitignore" "$EVAL_TMP/unpaired"
rc=0; out="$("$PIPELINE_ROOT/bin/install.sh" "$G" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && has "without its pair" && has "nothing was written" && cmp -s "$B0/.gitignore" "$EVAL_TMP/unpaired"; } \
  || die "FAIL G13: install went ahead with a marker without its pair" "exit $rc" "$out"
printf '/*/artifacts/\n' > "$B0/.gitignore"

# G14: the folder's .gitignore is never rewritten in place: a write that fails (a full disk, stood in for by an
# fsync that fails) leaves it byte-identical with nothing beside it, and a write that succeeds keeps its mode
OI="$PIPELINE_ROOT/core/hooks/order-ignore.py"; F="$EVAL_TMP/full"
mkdir -p "$F" && printf '*.tmp\r\nkeep me\r\n' > "$F/.gitignore" && cp "$F/.gitignore" "$EVAL_TMP/full.keep" || die "the eval could not make a .gitignore"
rc=0; out="$(python3 - "$OI" "$F" 2>&1 <<'PY'
import errno, os, runpy, sys
def full(fd):
    raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
os.fsync = full
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
)" || rc=$?
{ [ "$rc" -eq 3 ] && has "it is as it was" && cmp -s "$F/.gitignore" "$EVAL_TMP/full.keep" && [ "$(ls -A "$F")" = ".gitignore" ]; } \
  || die "FAIL G14: a write that failed changed the .gitignore or left a file beside it" "exit $rc" "$out" "$(ls -A "$F")" "$(od -c "$F/.gitignore" | head -4)"
chmod 640 "$F/.gitignore" && python3 "$OI" "$F" >/dev/null || die "FAIL G14: order-ignore failed on a writable .gitignore"
mode="$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$F/.gitignore")"
{ [ "$mode" = 0o640 ] && grep -qxF "$(printf '/*/artifacts/\r')" "$F/.gitignore" && grep -qxF "$(printf 'keep me\r')" "$F/.gitignore" && [ "$(ls -A "$F")" = ".gitignore" ]; } \
  || die "FAIL G14: a write that succeeded lost the file's mode or lines, or left a file beside it" "mode $mode" "$(ls -A "$F")"

# P1-P5: promote leaves the order's artifacts/ out of a playbook and says so when it held working files, sanitizes
# what it copies and names a finding in the order, refuses an artifacts/ that is not a plain folder, and leaves no stage
export TMPDIR="$EVAL_TMP/tmp/"; mkdir -p "$TMPDIR"
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q --no-git >/dev/null || die "the eval could not install a project"
cd q || exit 1
W=./.aicodepipeline/bin/wo; B=./.aicodepipeline/bin/bug
printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh
tok="ghp""_$(printf 'a%.0s' $(seq 1 36))"
for kind in wo bug; do
  DRV="$W"; [ "$kind" = bug ] && DRV="$B"
  if [ "$kind" = wo ]; then n="$($W new "Promote me" --size small --area backend | num WO)"; $W verify "$n" --run ./ok.sh >/dev/null; D="$(ls -d $W0/WO-"$n"-*)"
  else n="$($B new "Promote me" --category api | num BUG)"; $B verify "$n" --run ./ok.sh >/dev/null; D="$(ls -d $B0/BUG-"$n"-*)"; fi
  rc=0; out="$("$DRV" promote "$n" 2>&1)" || rc=$?
  { [ "$rc" -eq 0 ] && ! has "left out artifacts/"; } || die "FAIL P4: $kind promote spoke of an empty artifacts/" "exit $rc" "$out"
  m "$D/artifacts/runs/nightly/$kind-$n-alpha.log" "token $tok" && m "$D/artifacts/notes.md" "token $tok" && cp "$D"/*-VERIFICATION.md "$D/artifacts/copy-VERIFICATION.md" \
    || die "the eval could not fill artifacts/"
  rc=0; out="$("$DRV" promote "$n" 2>&1)" || rc=$?
  { [ "$rc" -eq 0 ] && has "promote: left out artifacts/ (3 files): working files stay with the order, never in a playbook"; } \
    || die "FAIL P1: $kind promote did not leave artifacts/ out and say so (the copy is what is scanned)" "exit $rc" "$out"
  PB="$(find .aicodepipeline/playbooks -type d -name "$(basename "$D")" | head -1)"
  { [ -n "$PB" ] && [ ! -e "$PB/artifacts" ] && ! grep -rq "$tok" "$PB"; } || die "FAIL P2: $kind promote carried artifacts/ or its token into the playbook ($PB)"
  [ -d "$D/artifacts/runs/nightly" ] || die "FAIL P2: $kind promote touched the order's own artifacts/"
  m "$D/leak.md" "token $tok"; rc=0; out="$("$DRV" promote "$n" 2>&1)" || rc=$?
  { [ "$rc" -ne 0 ] && has "relative to " && has "/$D:" && has "leak.md:1" && ! has "alpha.log"; } \
    || die "FAIL P5: $kind promote's sanitize refusal did not name the finding in the order, and only in what it copies" "exit $rc" "$out"
  rm "$D/leak.md"
  rm -r "$D/artifacts" && mkdir -p "$EVAL_TMP/elsewhere" && ln -s "$EVAL_TMP/elsewhere" "$D/artifacts" || die "the eval could not link artifacts/"
  rc=0; out="$("$DRV" promote "$n" 2>&1)" || rc=$?
  { [ "$rc" -ne 0 ] && has "artifacts is not a plain folder"; } || die "FAIL P3: $kind promote went ahead with artifacts/ a link" "exit $rc" "$out"
  rm "$D/artifacts"
done
[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'acp-promote.*')" ] || die "FAIL P5: promote left its stage behind" "$(ls -A "$TMPDIR")"
echo "order-structure: all checks passed"
exit 0
