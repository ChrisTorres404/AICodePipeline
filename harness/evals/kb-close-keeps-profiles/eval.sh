#!/usr/bin/env bash
# A close grows the knowledge base; it must never damage it. A project whose profiles are written by hand, named their own way
# and split finer than the scaffold groups (one profile per package of one source directory, `feature: engine-make` in a file
# called making.md) had every such profile rewritten to `status: orphaned` at every close, with "the directory is gone" while
# every directory existed, and a profile added for the pipeline's own document folder because a helper script sat there.
# This checks how a profile's paths are read (citations relative to the profile, wildcards, backslashes, `./`, words that are
# not paths, a feature key with no path), which folders are features, then drives real closes over that shape: a plain close
# changes nothing; with a package gone, the strict profile refuses and leaves nothing new on disk, an override records the
# report in the closing record, and a failed grow step is recorded as failed.
set -uo pipefail
. "$(dirname "$0")/../_lib/verification.sh"
KB_PY="$PIPELINE_ROOT/core/hooks/kb.py"
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
sums() { ( cd "$1" && for f in *.md; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done ); }
tree_sums() { ( cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done ); }
hand() { # <kb> <file name> <feature key> <body lines...>: a profile a person wrote (no scaffold_prompts)
  local kb="$1" file="$2" key="$3"; shift 3; mkdir -p "$kb/profiles"
  { printf -- '---\ntitle: "%s"\nstatus: WRITTEN\nfeature: %s\nlevel: lite\nvalidated: false\n---\n\n# %s\n\n' "$file" "$key" "$file"
    printf '%s\n' "$@"; } > "$kb/profiles/$file"
}

# --- 0a. how a profile's paths are read --------------------------------------------------------------------------------
H="$EVAL_TMP/paths"; HKB="$H/Workspace/Docs/KnowledgeBase"; mkdir -p "$H/engine/brain" "$H/engine/checks"
printf 'def a():\n    return 1\n' > "$H/engine/brain/one.py"; printf 'def b():\n    return 2\n' > "$H/engine/brain/two.py"
printf 'def c():\n    return 3\n' > "$H/engine/checks/one.py"; printf 'def d():\n    return 4\n' > "$H/engine/checks/two.py"
HK() { python3 "$KB_PY" "$@" --root "$H" --kb "$HKB"; }
# a citation written relative to the profile's own folder, the spelling `citations()` accepts
hand "$HKB" docrel.md brain-rel 'It thinks. <!-- SOURCE: ../../../../engine/brain/one.py:L1 -->'
hand "$HKB" globcov.md brain-glob '**Covers:** `engine/brain/*.py`'
hand "$HKB" winpath.md brain-win '**Covers:** `engine\brain\one.py`'
hand "$HKB" dotted.md checks-dotted '**Covers:** `./engine/checks`'
hand "$HKB" notpath.md brain-words '**Covers:** `engine/brain/two.py` `run()` `BrainLoop`'
out="$(HK scaffold --grow 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "grow exited $rc over profiles whose paths all exist (expected 0)" "$out"
echo "$out" | grep -q "no longer exist" && die "grow called a path missing that exists (relative, wildcard, backslash, ./ or a word)" "$out"
for f in "$HKB"/profiles/*.md; do case "$(basename "$f")" in docrel.md|globcov.md|winpath.md|dotted.md|notpath.md) ;; *)
  die "grow added $(basename "$f") for code a profile already covers (by a wildcard, a backslash or a ./ path)" "$out";; esac; done
out="$(HK scaffold 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "an explicit scaffold exited $rc" "$out"
grep -l '^status: orphaned' "$HKB"/profiles/*.md && die "an explicit scaffold marked a profile orphaned whose paths exist"
echo "$out" | grep -q "no longer exist" && die "an explicit scaffold called a path missing that exists" "$out"
# a word on the Covers line is not a path: only the real path is named when the code goes
hand "$HKB" wordsgone.md gone-words '**Covers:** `engine/gone/x.py` `run()` `BrainLoop`'
out="$(HK scaffold --grow 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || die "grow exited $rc with a profile whose paths are gone (expected 3)" "$out"
echo "$out" | grep "wordsgone" | grep -q "engine/gone/x.py" || die "grow did not name the missing path" "$out"
echo "$out" | grep "wordsgone" | grep -q "run()" && die "grow named a word that is not a path as a missing path" "$out"
# a scaffold-written profile renamed so its name is not the scaffold's, citing its code relative to its own folder
S="$EVAL_TMP/rel"; SKB="$S/Workspace/Docs/KnowledgeBase"; mkdir -p "$S/src/util" "$S/src/auth"
printf 'export const l = 1;\n' > "$S/src/util/l.ts"; printf 'export const a = 1;\n' > "$S/src/auth/a.ts"
python3 "$KB_PY" scaffold --root "$S" --kb "$SKB" >/dev/null 2>&1 || die "the renamed-profile fixture would not scaffold"
sed 's#SOURCE: src/util/#SOURCE: ../../../../src/util/#g' "$SKB/profiles/util.md" > "$SKB/profiles/utility.md"; rm "$SKB/profiles/util.md"
grep -q '^scaffold_prompts:' "$SKB/profiles/utility.md" || die "the fixture's scaffold profile carries no scaffold_prompts"
out="$(python3 "$KB_PY" scaffold --root "$S" --kb "$SKB" 2>&1)" || die "re-scaffolding the renamed fixture failed" "$out"
grep -q '^status: orphaned' "$SKB/profiles/utility.md" && die "an explicit scaffold orphaned a renamed scaffold profile whose code exists" "$out"
[ -f "$SKB/profiles/util.md" ] && die "the scaffold added util.md for code the renamed profile covers" "$out"

# --- 0b. which folders are features ----------------------------------------------------------------------------------------
# a knowledge base kept inside a code folder: that folder's code is still a feature; the documents folder is not
C="$EVAL_TMP/inside"; mkdir -p "$C/server/auth" "$C/server/billing" "$C/server/docs/tools" "$C/web"
printf 'def a():\n    return 1\n' > "$C/server/auth/a.py"; printf 'def b():\n    return 1\n' > "$C/server/billing/b.py"
printf 'export const x = 1;\n' > "$C/web/x.ts"; printf 'print("a helper kept with the documents")\n' > "$C/server/docs/tools/h.py"
out="$(python3 "$KB_PY" scaffold --root "$C" --kb "$C/server/docs/kb" 2>&1)" || die "the inside fixture would not scaffold" "$out"
grep -l 'server/auth/a.py' "$C"/server/docs/kb/profiles/*.md >/dev/null 2>&1 || die "code in the folder that holds the knowledge base got no profile" "$out"
grep -l 'server/billing/b.py' "$C"/server/docs/kb/profiles/*.md >/dev/null 2>&1 || die "code in the folder that holds the knowledge base got no profile" "$out"
grep -l 'server/docs/tools/h.py' "$C"/server/docs/kb/profiles/*.md >/dev/null 2>&1 && die "the knowledge base's own folder was made a feature" "$out"

# --- 0c. a profile that names no path is checked through its feature key ---------------------------------------------------
F="$EVAL_TMP/key"; FKB="$F/Workspace/Docs/KnowledgeBase"; mkdir -p "$F/src/auth" "$F/src/util" "$F/engine/brain" "$F/engine/main"
printf 'export const a = 1;\n' > "$F/src/auth/a.ts"; printf 'export const u = 1;\n' > "$F/src/util/u.ts"
printf 'def m():\n    return 1\n' > "$F/engine/brain/m.py"; printf 'def n():\n    return 1\n' > "$F/engine/main/n.py"
python3 "$KB_PY" scaffold --root "$F" --kb "$FKB" >/dev/null 2>&1 || die "the feature-key fixture would not scaffold"
{ printf -- '---\ntitle: "Auth"\nstatus: WRITTEN\nfeature: auth\nscaffold_prompts: 3\n---\n\n# Auth\n\nIt logs people in.\n'; } > "$FKB/profiles/auth.md"
hand "$FKB" thinking.md engine-brain 'It thinks; no path is named.'
out="$(python3 "$KB_PY" scaffold --grow --root "$F" --kb "$FKB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "grow exited $rc while every feature key names a directory that exists" "$out"
echo "$out" | grep -qE "auth|thinking" && die "grow reported a profile whose feature key names a directory that exists" "$out"
mv "$F/src/auth" "$F/src/login"; mv "$F/engine/brain" "$F/engine/mind"
cp "$FKB/profiles/thinking.md" "$EVAL_TMP/thinking-before.md"
out="$(python3 "$KB_PY" scaffold --grow --root "$F" --kb "$FKB" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || die "grow exited $rc after the directories moved (expected 3)" "$out"
echo "$out" | grep "profiles/auth.md" | grep -q "feature key" || die "grow did not report the profile whose directory moved" "$out"
echo "$out" | grep "profiles/thinking.md" | grep -q "engine-brain" || die "grow did not report the hand profile whose directory moved" "$out"
out="$(python3 "$KB_PY" scaffold --root "$F" --kb "$FKB" 2>&1)" || die "the explicit scaffold failed" "$out"
grep -q '^status: orphaned' "$FKB/profiles/auth.md" || die "an explicit scaffold did not mark the moved scaffold profile orphaned" "$out"
cmp -s "$EVAL_TMP/thinking-before.md" "$FKB/profiles/thinking.md" || die "an explicit scaffold rewrote a hand profile"

# --- 1. the damaged shape: hand profiles named their own way, split finer than the scaffold groups -------------------------
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P >/dev/null 2>&1 || die "new-project failed"
cd p || exit 1
KB=Workspace/Docs/KnowledgeBase; W=./.aicodepipeline/bin/wo
K() { python3 "$KB_PY" "$@" --root "$PWD" --kb "$PWD/$KB"; }
mkdir -p engine/brain engine/checks/core engine/checks/io engine/make engine/tools Workspace/Docs/Audit
for d in brain checks/core checks/io make tools; do
  printf 'def %s_one():\n    return 1\n' "${d//\//_}" > "engine/$d/one.py"
  printf 'def %s_two():\n    return 2\n' "${d//\//_}" > "engine/$d/two.py"
done
printf 'def main():\n    return 0\n' > engine/main.py
printf 'print("kept with the documents as evidence")\n' > Workspace/Docs/Audit/repro.py
profile() { # <file> <feature key> <title> <cited path>...
  local file="$1" key="$2" title="$3"; shift 3
  { printf -- '---\ntitle: "%s"\nstatus: WRITTEN\nfeature: %s\nlevel: lite\nvalidated: false\n---\n\n# %s\n\n' "$title" "$key" "$title"
    printf '**Covers:**'; for c in "$@"; do printf ' `%s`' "$c"; done; printf '\n\n'
    for c in "$@"; do printf 'It does what the code says. <!-- SOURCE: %s:L1 -->\n' "$c"; done
  } > "$KB/profiles/$file"
}
profile entry.md entry "The entry point" engine/main.py
profile brain.md brain "The brain" engine/brain/one.py engine/brain/two.py
profile checks-core.md checks-core "The core checks" engine/checks/core/one.py engine/checks/core/two.py
profile checks-io.md checks-io "The input checks" engine/checks/io/one.py
profile making.md engine-make "Making documents" engine/make/one.py engine/make/two.py
# one profile the scaffold wrote (it carries scaffold_prompts), renamed by a person: its name is not live, its code is there
{ printf -- '---\ntitle: "Toolbox"\nstatus: SCAFFOLD\nfeature: toolbox\nscaffold_prompts: 11\n---\n\n# Toolbox\n\n'
  printf 'Read by the scaffold. <!-- SOURCE: engine/tools/one.py:L1 --> <!-- SOURCE: engine/tools/two.py:L1 -->\n'; } > "$KB/profiles/toolbox.md"
K bind >/dev/null 2>&1 || die "the hand-written profiles would not bind"
out="$(K status 2>&1)"; [ "$(echo "$out" | grep -c '^profiles/.* current')" -eq 6 ] || die "the fixture's six profiles are not current" "$out"
sums "$KB/profiles" > "$EVAL_TMP/before"
# an explicit scaffold over this shape judges every profile by its paths: none orphaned, none reported, none added
out="$(K scaffold 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "an explicit scaffold over the fixture exited $rc" "$out"
echo "$out" | grep -qE "no longer exist|not marked" && die "an explicit scaffold reported a profile whose paths exist" "$out"
sums "$KB/profiles" > "$EVAL_TMP/after"
diff "$EVAL_TMP/before" "$EVAL_TMP/after" >/dev/null || { echo "an explicit scaffold changed or added profiles:"; diff "$EVAL_TMP/before" "$EVAL_TMP/after"; echo "$out"; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > ok.sh; chmod +x ok.sh
git add -A >/dev/null; git -c user.email=e@x -c user.name=e commit -q -m base
wo_ready() { # <title> -> number of a work order ready to close
  local n; n="$($W new "$1" --size trivial | grep -o 'WO-[0-9]*' | head -1)"; n="${n#WO-}"
  $W verify "$n" --run ./ok.sh >/dev/null 2>&1 || die "verify failed"
  fill_wo "$n"; echo "$n"
}
closeout() { ls Workspace/Docs/WorkOrders/WO-"$1"-*/WO-"$1"-CLOSEOUT.md 2>/dev/null | head -1; }

# a close over that shape changes no profile and adds none
n="$(wo_ready "Touch nothing")"
out="$($W close "$n" 2>&1)" || die "close failed" "$out"
sums "$KB/profiles" > "$EVAL_TMP/after"
diff "$EVAL_TMP/before" "$EVAL_TMP/after" >/dev/null || { echo "the close changed or added profiles:"; diff "$EVAL_TMP/before" "$EVAL_TMP/after"; exit 1; }
grep -l '^status: orphaned' "$KB"/profiles/*.md 2>/dev/null && die "a profile whose code exists was marked orphaned"
echo "$out" | grep -qiE "orphaned|no longer exist" && die "the close spoke of missing paths while every covered path exists" "$out"
out="$(K status 2>&1)"; [ "$(echo "$out" | grep -c '^profiles/.* current')" -eq 6 ] || die "the profiles are not all current after the close" "$out"

# --- 2. a package really goes, and new code arrives --------------------------------------------------------------------------
rm -rf engine/make
mkdir -p engine/extra; printf 'def e():\n    return 1\n' > engine/extra/one.py; printf 'def f():\n    return 2\n' > engine/extra/two.py
cp "$KB/profiles/making.md" "$EVAL_TMP/make-before.md"
tree_sums "$KB" > "$EVAL_TMP/kb-before"
out="$(K scaffold --grow --check 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || die "the report-only grow exited $rc with a profile whose paths are gone (expected 3)" "$out"
echo "$out" | grep "making.md" | grep -q "engine/make/one.py" || die "the report-only grow did not name the profile and its missing paths" "$out"
tree_sums "$KB" > "$EVAL_TMP/kb-after"
diff "$EVAL_TMP/kb-before" "$EVAL_TMP/kb-after" >/dev/null || { echo "the report-only grow wrote to the knowledge base:"; diff "$EVAL_TMP/kb-before" "$EVAL_TMP/kb-after"; exit 1; }
out="$(K scaffold 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || die "scaffold exited $rc" "$out"
cmp -s "$EVAL_TMP/make-before.md" "$KB/profiles/making.md" || { echo "a profile a person wrote was rewritten:"; diff "$EVAL_TMP/make-before.md" "$KB/profiles/making.md"; exit 1; }
echo "$out" | grep "making.md" | grep -q "engine/make/one.py" || die "scaffold did not report the hand-written profile whose paths are gone" "$out"
rm -f "$KB"/profiles/*extra*.md; K bind >/dev/null 2>&1   # put the knowledge base back as it was before the explicit scaffold
git add -A >/dev/null; git -c user.email=e@x -c user.name=e commit -q -m "make goes, extra arrives"
tree_sums "$KB" > "$EVAL_TMP/kb-before"

# under the strict profile the close refuses, says why, writes no closing record, and leaves nothing new on disk
n="$(wo_ready "Strict close")"
out="$(ACP_STRICT=1 $W close "$n" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || die "the strict profile closed with a profile whose covered paths are gone" "$out"
echo "$out" | grep -q "making.md" || die "the strict refusal did not name the profile" "$out"
echo "$out" | grep -q "engine/make/one.py" || die "the strict refusal did not name the missing path" "$out"
echo "$out" | grep -q "refusing to close WO-$n" || die "the strict refusal did not say it refused" "$out"
echo "$out" | grep -q "with a reason in the closeout" || die "the strict refusal's override does not ask for a reason" "$out"
[ -z "$(closeout "$n")" ] || die "a refused close wrote a closing record" "$(closeout "$n")"
tree_sums "$KB" > "$EVAL_TMP/kb-after"
diff "$EVAL_TMP/kb-before" "$EVAL_TMP/kb-after" >/dev/null || { echo "a refused close left changes in the knowledge base:"; diff "$EVAL_TMP/kb-before" "$EVAL_TMP/kb-after"; exit 1; }

# the override closes, prints every line of the report, and the closing record holds it under its own heading
out="$(ACP_STRICT=1 ACP_SKIP_KB=1 $W close "$n" 2>&1)" || die "the overridden close failed" "$out"
echo "$out" | grep "making.md" | grep -q "engine/make/one.py" || die "the close did not print the profile whose paths are gone" "$out"
echo "$out" | grep -q "profiles added (engine-extra)" || die "the close did not print the stub it added" "$out"
cmp -s "$EVAL_TMP/make-before.md" "$KB/profiles/making.md" || die "the close rewrote a profile a person wrote"
co="$(closeout "$n")"; [ -n "$co" ] || die "the overridden close wrote no closing record" "$out"
grep -q '^### Knowledge base changes at close' "$co" || { echo "the closing record has no heading for grow's report:"; cat "$co"; exit 1; }
sed -n '/^### Knowledge base changes at close/,$p' "$co" > "$EVAL_TMP/grow-section"
grep "making.md" "$EVAL_TMP/grow-section" | grep -q "engine/make/one.py" || { echo "the closing record does not hold the missing paths:"; cat "$co"; exit 1; }
grep -q "profiles added (engine-extra)" "$EVAL_TMP/grow-section" || { echo "the closing record does not hold the stub added:"; cat "$co"; exit 1; }
grep -q "ACP_SKIP_KB=1" "$EVAL_TMP/grow-section" || { echo "the closing record does not say the strict refusal was overridden:"; cat "$co"; exit 1; }
grep -q '^grow: ' "$co" && { echo "the closing record keeps the raw grow: prefix:"; cat "$co"; exit 1; }

# --- 3. a failed grow step is shown and recorded, and claims nothing it did not check ----------------------------------------
t="$(find .aicodepipeline -name feature-profile.md | head -1)"; [ -n "$t" ] || die "the installed profile template was not found"
mv "$t" "$t.off"
n="$(wo_ready "Grow fails")"
out="$($W close "$n" 2>&1)"; rc=$?; mv "$t.off" "$t"
[ "$rc" -eq 0 ] || die "a failed grow step stopped a close that is not strict" "$out"
echo "$out" | grep -q "the grow step failed (exit 1)" || die "the close did not say the grow step failed" "$out"
echo "$out" | grep -q "nothing was added" && die "the failure message claims nothing was added, which was not checked" "$out"
echo "$out" | grep -q "template is missing" || die "the close hid the grow step's error output" "$out"
co="$(closeout "$n")"; [ -n "$co" ] || die "the close wrote no closing record" "$out"
grep -q "the grow step failed (exit 1)" "$co" || { echo "the closing record does not record the failed grow:"; cat "$co"; exit 1; }
grep -q "template is missing" "$co" || { echo "the closing record does not keep the grow step's output:"; cat "$co"; exit 1; }

# --- 4. a scaffold profile whose code goes: grow reports it, an explicit scaffold marks it ---------------------------------
G="$EVAL_TMP/g"; GKB="$G/Workspace/Docs/KnowledgeBase"
mkdir -p "$G/src/auth" "$G/src/util"
printf 'export function login() {}\nexport function out() {}\n' > "$G/src/auth/login.ts"
printf 'export const log = (m: string) => m;\n' > "$G/src/util/log.ts"
python3 "$KB_PY" scaffold --root "$G" --kb "$GKB" >/dev/null 2>&1 || die "the second fixture would not scaffold"
rm -rf "$G/src/util"; cp "$GKB/profiles/util.md" "$EVAL_TMP/util-before.md"
out="$(python3 "$KB_PY" scaffold --grow --root "$G" --kb "$GKB" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || die "grow exited $rc on the second fixture (expected 3: a profile's paths are gone)" "$out"
cmp -s "$EVAL_TMP/util-before.md" "$GKB/profiles/util.md" || die "grow rewrote an existing profile; at close it only adds"
echo "$out" | grep "util" | grep -q "acp kb scaffold" || die "grow did not report the scaffold profile, or did not name acp kb scaffold" "$out"
out="$(python3 "$KB_PY" scaffold --root "$G" --kb "$GKB" 2>&1)" || die "scaffold failed on the second fixture" "$out"
grep -q '^status: orphaned' "$GKB/profiles/util.md" || die "an explicit scaffold did not mark the scaffold profile orphaned"

# --- 5. a new feature nobody describes still gets a profile; one already described does not --------------------------------
ls "$KB/profiles" > "$EVAL_TMP/list-before"
mkdir -p engine/search; printf 'def find():\n    return []\n' > engine/search/one.py; printf 'def rank():\n    return 0\n' > engine/search/two.py
: > engine/search/__init__.py   # an empty package marker sorts first: the stub must not cite a line it does not have
out="$(K scaffold --grow 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || die "grow exited $rc (expected 3: making.md still covers paths that are gone)" "$out"
ls "$KB/profiles" > "$EVAL_TMP/list-after"
[ "$(comm -13 "$EVAL_TMP/list-before" "$EVAL_TMP/list-after" | tr '\n' ' ')" = "engine-search.md " ] \
  || { echo "grow should add exactly one profile, for the package nobody covers:"; comm -13 "$EVAL_TMP/list-before" "$EVAL_TMP/list-after"; echo "$out"; exit 1; }
out="$(K status 2>&1)"
echo "$out" | grep "search" | grep -q "broken" && die "the new stub cites a line an empty file does not have" "$out"
grep -q "engine/search/__init__.py:L" "$KB"/profiles/*search*.md && die "the stub cites the empty package marker"
[ -f "$KB/profiles/workspace.md" ] && die "the pipeline's own document folder was made a feature"
exit 0
