#!/usr/bin/env bash
# worktree-lifecycle: wo start makes the work order's branch wo/NNNN-slug and its git worktree under
# <workspace>/Worktrees/, ignored by git and read by no check; wo close removes both only when nothing can be
# lost, and otherwise keeps them and says why. wo start refuses an order whose documents are not committed, and a
# closed one; wo close refuses while the branch is not merged (ALLOW_UNMERGED=1 overrides); wo verify and wo close
# refuse inside a worktree.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
die() { echo "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 1; }
G() { git -c user.name=t -c user.email=t@example.com "$@"; }
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1; cd p || die "new-project failed"
{ G init -q && mkdir -p src && printf 'export const a = 1;\n' > src/a.ts && printf '.env\nnode_modules/\n' >> .gitignore && G add -A && G commit -qm base; } || die "could not make the first commit"
P="$(pwd -P)"; W=./.aicodepipeline/bin/wo; WT=Workspace/Worktrees
mkdir -p s && printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' > s/ok.sh
# open <title>: a new order, its documents committed (wo start refuses an order whose documents are not)
open() {
  local n; n="$($W new "$1" --size small 2>/dev/null | grep -o 'WO-[0-9]*' | head -1 | sed 's/^WO-//')"
  { G add -A Workspace/Docs/WorkOrders && G commit -qm "WO-$n open"; } >/dev/null 2>&1; printf '%s' "$n"
}
closeout() { ls Workspace/Docs/WorkOrders/WO-"$1"-*/WO-"$1"-CLOSEOUT.md >/dev/null 2>&1; }
listed() { G worktree list --porcelain | grep -qxF "worktree $P/$1"; }
fp0="$($W fingerprint)"

# W1: wo start makes the order's branch and its worktree, and names them
n="$(open "Alpha")"; [ -n "$n" ] || die "wo new failed"
out="$($W start "$n" 2>&1)" || die "FAIL W1: wo start failed" "$out"
listed "$WT/wo-$n-alpha" || die "FAIL W1: wo start made no worktree for the work order" "$out"
[ "$(G -C "$WT/wo-$n-alpha" symbolic-ref --short HEAD 2>/dev/null)" = "wo/$n-alpha" ] || die "FAIL W1: the worktree is not on branch wo/$n-alpha" "$out"
{ printf '%s\n' "$out" | grep -qxF "WO-$n: worktree $P/$WT/wo-$n-alpha on branch wo/$n-alpha" \
  && printf '%s\n' "$out" | grep -qxF "WO-$n: work in the worktree; run wo commands (verify, close) from the main checkout, $P"; } \
  || die "FAIL W1: wo start did not name the worktree's full path, its branch, and where wo commands run" "$out"
meta="$(ls -d Workspace/Docs/WorkOrders/WO-"$n"-alpha)/.wo-meta"
{ grep -qxF "branch=wo/$n-alpha" "$meta" && grep -qxF "worktree=$WT/wo-$n-alpha" "$meta"; } || die "FAIL W1: wo start did not record the branch and the worktree in .wo-meta" "$(cat "$meta")"

# W2: the main checkout sees no change, and the source fingerprint is the same
G status --porcelain | grep -qF "$WT" && die "FAIL W2: the worktree shows as a change in the main checkout" "$(G status --porcelain)"
[ "$($W fingerprint)" = "$fp0" ] || die "FAIL W2: making the worktree changed the source fingerprint"

# W3: starting the order again reuses its worktree
out="$($W start "$n" 2>&1)" || die "FAIL W3: a second wo start failed" "$out"
[ "$(G worktree list --porcelain | grep -c '^worktree ')" = 2 ] || die "FAIL W3: a second wo start made another worktree" "$(G worktree list)"

# W4: the close-time checks do not read the worktree's files as the project's
python3 .aicodepipeline/core/hooks/check.py --root "$P" --write-manifest "$EVAL_TMP/m.tsv" --exclude .aicodepipeline >/dev/null 2>&1 \
  || die "check.py could not write a manifest"
grep -qF "$WT/wo-" "$EVAL_TMP/m.tsv" && die "FAIL W4: the close-time checks read the worktree's files as the project's" "$(grep -cF "$WT/wo-" "$EVAL_TMP/m.tsv") file(s)"
# W4b: a folder whose .git file names a git directory with no commondir (a submodule's) is still read
mkdir -p "$EVAL_TMP/sm/sub" "$EVAL_TMP/sm-gitdir" && printf 'gitdir: %s\n' "$EVAL_TMP/sm-gitdir" > "$EVAL_TMP/sm/sub/.git" && printf 'kept\n' > "$EVAL_TMP/sm/sub/keep.txt"
python3 .aicodepipeline/core/hooks/check.py --root "$EVAL_TMP/sm" --write-manifest "$EVAL_TMP/sm.tsv" >/dev/null 2>&1 || die "check.py could not write the submodule manifest"
grep -qF 'sub/keep.txt' "$EVAL_TMP/sm.tsv" || die "FAIL W4b: the close-time checks skipped a submodule-like folder as if it were a worktree"

# W5: once its branch is merged, wo close removes the worktree and deletes the branch
printf 'export const b = 2;\n' > "$WT/wo-$n-alpha/src/b.ts"
{ G -C "$WT/wo-$n-alpha" add -A && G -C "$WT/wo-$n-alpha" commit -qm "WO-$n b" && G merge -q --ff-only "wo/$n-alpha"; } || die "could not commit in the worktree and merge it"
# W5a: a close the verification guard refuses leaves the worktree and the branch alone
rc=0; out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || die "wo close did not refuse an order with no verification" "$out"
{ listed "$WT/wo-$n-alpha" && G show-ref --verify -q "refs/heads/wo/$n-alpha"; } || die "FAIL W5a: a refused wo close removed the worktree or the branch" "$out"
$W verify "$n" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$n" 2>&1)" || die "FAIL W5: wo close failed" "$out"
listed "$WT/wo-$n-alpha" && die "FAIL W5: wo close kept the worktree of a merged branch" "$out"
G show-ref --verify -q "refs/heads/wo/$n-alpha" && die "FAIL W5: wo close kept a merged branch" "$out"
printf '%s\n' "$out" | grep -qF "WO-$n: worktree $WT/wo-$n-alpha removed and branch wo/$n-alpha deleted" || die "FAIL W5: wo close did not say it removed the worktree" "$out"

# W6: while its branch holds a commit the main checkout lacks, wo close refuses before writing a closeout and
# changes nothing; ALLOW_UNMERGED=1 closes it, and the worktree and the branch are then kept, saying why
m="$(open "Beta")"; $W start "$m" >/dev/null 2>&1 || die "wo start failed"
printf 'export const c = 3;\n' > "$WT/wo-$m-beta/src/c.ts"
{ G -C "$WT/wo-$m-beta" add -A && G -C "$WT/wo-$m-beta" commit -qm "WO-$m c"; } || die "could not commit in the worktree"
$W verify "$m" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
rc=0; out="$(ALLOW_PLACEHOLDERS=1 $W close "$m" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && ! closeout "$m" \
  && printf '%s\n' "$out" | grep -qF "refusing to close WO-$m: branch wo/$m-beta has 1 commit(s) the main checkout's HEAD does not" \
  && printf '%s\n' "$out" | grep -qF "Merge wo/$m-beta first" \
  && printf '%s\n' "$out" | grep -qF "If it was squash- or rebase-merged, close with ALLOW_UNMERGED=1"; } || die "FAIL W6: wo close did not refuse an order whose branch is not merged" "$out"
{ listed "$WT/wo-$m-beta" && G show-ref --verify -q "refs/heads/wo/$m-beta"; } || die "FAIL W6: a refused wo close changed the worktree or the branch" "$out"
out="$(ALLOW_UNMERGED=1 ALLOW_PLACEHOLDERS=1 $W close "$m" 2>&1)" || die "FAIL W6: wo close with ALLOW_UNMERGED=1 failed" "$out"
listed "$WT/wo-$m-beta" || die "FAIL W6: wo close removed the worktree of a branch that is not merged" "$out"
G show-ref --verify -q "refs/heads/wo/$m-beta" || die "FAIL W6: wo close deleted a branch that is not merged" "$out"
printf '%s\n' "$out" | grep -qF "WO-$m: worktree $WT/wo-$m-beta kept: branch wo/$m-beta is not merged" || die "FAIL W6: wo close did not say why it kept the worktree" "$out"

# W7: a worktree holding uncommitted work is kept, even when its branch is merged
k="$(open "Gamma")"; $W start "$k" >/dev/null 2>&1 || die "wo start failed"
printf 'scratch\n' > "$WT/wo-$k-gamma/notes.txt"
$W verify "$k" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$k" 2>&1)" || die "FAIL W7: wo close failed" "$out"
listed "$WT/wo-$k-gamma" || die "FAIL W7: wo close removed a worktree that holds uncommitted work" "$out"
printf '%s\n' "$out" | grep -qF "WO-$k: worktree $WT/wo-$k-gamma kept: it holds uncommitted work (notes.txt)" || die "FAIL W7: wo close did not say why it kept the worktree" "$out"

# W8: a folder in the worktree's place that is not a worktree is refused, and the order is not started
x="$(open "Delta")"; mkdir -p "$WT/wo-$x-delta"
rc=0; out="$($W start "$x" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || die "FAIL W8: wo start used a folder that is not a worktree" "$out"
grep -q '^status=in-progress' Workspace/Docs/WorkOrders/WO-"$x"-delta/.wo-meta && die "FAIL W8: a refused wo start marked the order in progress"

# W10: a worktree whose HEAD left the order's branch (detached here, with a commit no ref holds) is kept
e="$(open "Epsilon")"; $W start "$e" >/dev/null 2>&1 || die "wo start failed"
{ G -C "$WT/wo-$e-epsilon" checkout -q --detach && printf 'export const e = 5;\n' > "$WT/wo-$e-epsilon/src/e.ts" && G -C "$WT/wo-$e-epsilon" add -A && G -C "$WT/wo-$e-epsilon" commit -qm "WO-$e detached"; } || die "could not commit on a detached HEAD"
$W verify "$e" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$e" 2>&1)" || die "FAIL W10: wo close failed" "$out"
{ [ -d "$WT/wo-$e-epsilon" ] && listed "$WT/wo-$e-epsilon"; } || die "FAIL W10: wo close removed a worktree whose HEAD is not on the order's branch" "$out"
printf '%s\n' "$out" | grep -qF "WO-$e: worktree $WT/wo-$e-epsilon kept: it is not on wo/$e-epsilon" || die "FAIL W10: wo close did not say the worktree left its branch" "$out"

# W11: a clean, merged worktree that holds a file git ignores and that is not disposable (a .env) is kept, named
z="$(open "Zeta")"; $W start "$z" >/dev/null 2>&1 || die "wo start failed"
printf 'SECRET=1\n' > "$WT/wo-$z-zeta/.env"
$W verify "$z" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$z" 2>&1)" || die "FAIL W11: wo close failed" "$out"
[ -f "$WT/wo-$z-zeta/.env" ] || die "FAIL W11: wo close removed a worktree holding a file git ignores" "$out"
printf '%s\n' "$out" | grep -qF "WO-$z: worktree $WT/wo-$z-zeta kept: it holds files git ignores (.env)" || die "FAIL W11: wo close did not name the ignored files it kept" "$out"

# W12: a worktree moved with mv is missing to git: close changes nothing and says so, wo start refuses, and the
# way out it gives (repair, then move back) works
h="$(open "Eta")"; $W start "$h" >/dev/null 2>&1 || die "wo start failed"
mv "$WT/wo-$h-eta" "$EVAL_TMP/moved-eta"
rc=0; out="$($W start "$h" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "its worktree $WT/wo-$h-eta is missing"; } || die "FAIL W12: wo start did not refuse while the worktree is missing" "$out"
G worktree repair "$EVAL_TMP/moved-eta" >/dev/null 2>&1 || die "git worktree repair failed"
rc=0; out="$($W start "$h" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "its worktree is at "; } || die "FAIL W12: after a repair wo start did not say where the worktree is" "$out"
G worktree move "$EVAL_TMP/moved-eta" "$WT/wo-$h-eta" || die "could not move the worktree back"
out="$($W start "$h" 2>&1)" || die "FAIL W12: wo start failed once the worktree was moved back" "$out"
listed "$WT/wo-$h-eta" || die "FAIL W12: the worktree moved back is not listed in its place" "$out"
mv "$WT/wo-$h-eta" "$EVAL_TMP/moved-eta"
$W verify "$h" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$h" 2>&1)" || die "FAIL W12: wo close failed" "$out"
printf '%s\n' "$out" | grep -qF "WO-$h: worktree $WT/wo-$h-eta is missing (moved or deleted); nothing removed" || die "FAIL W12: wo close did not say the worktree is missing" "$out"
{ [ -f "$EVAL_TMP/moved-eta/src/a.ts" ] && G show-ref --verify -q "refs/heads/wo/$h-eta"; } || die "FAIL W12: wo close changed a missing worktree or its branch" "$out"

# W13: a worktree moved with git worktree move (to a path holding a space) is named where it is: wo start refuses
# with advice that pastes as one path, and close removes nothing
o="$(open "Theta")"; $W start "$o" >/dev/null 2>&1 || die "wo start failed"
G worktree move "$WT/wo-$o-theta" "$EVAL_TMP/moved theta" || die "could not move the worktree"
rc=0; out="$($W start "$o" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "its worktree is at " \
  && printf '%s\n' "$out" | grep -qF "git worktree move $(printf '%q' "$(cd "$EVAL_TMP" && pwd -P)/moved theta") $WT/wo-$o-theta"; } \
  || die "FAIL W13: wo start did not say where the moved worktree is, quoted" "$out"
$W verify "$o" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$o" 2>&1)" || die "FAIL W13: wo close failed" "$out"
printf '%s\n' "$out" | grep -qF "WO-$o: the worktree of branch wo/$o-theta is at " || die "FAIL W13: wo close did not say where the moved worktree is" "$out"
{ [ -d "$EVAL_TMP/moved theta" ] && G show-ref --verify -q "refs/heads/wo/$o-theta"; } || die "FAIL W13: wo close changed a moved worktree or its branch" "$out"

# W14: a worktree someone locked is kept: git, not a delete, removes a worktree
l="$(open "Iota")"; $W start "$l" >/dev/null 2>&1 || die "wo start failed"
G worktree lock --reason "kept by hand" "$WT/wo-$l-iota" || die "could not lock the worktree"
$W verify "$l" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$l" 2>&1)" || die "FAIL W14: wo close failed" "$out"
{ [ -d "$WT/wo-$l-iota" ] && listed "$WT/wo-$l-iota"; } || die "FAIL W14: wo close removed a locked worktree" "$out"
printf '%s\n' "$out" | grep -qF "WO-$l: worktree $WT/wo-$l-iota kept: git would not remove it" || die "FAIL W14: wo close did not say why it kept the locked worktree" "$out"

# W16: an ignored folder whose name is on the disposable list (app/node_modules/, as in an app/ + acp/ layout)
# goes with a merged, clean worktree; any other ignored file (app/.env) still keeps it, and only that file is named.
# app/ holds tracked code, as it does in a project; a folder holding only ignored files is reported whole (app/).
{ mkdir -p app && printf 'export const app = 1;\n' > app/index.ts && G add app && G commit -qm "add app"; } || die "could not commit app/"
j="$(open "Kappa")"; $W start "$j" >/dev/null 2>&1 || die "wo start failed"
mkdir -p "$WT/wo-$j-kappa/app/node_modules/x" && printf 'x\n' > "$WT/wo-$j-kappa/app/node_modules/x/i.js"
$W verify "$j" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$j" 2>&1)" || die "FAIL W16: wo close failed" "$out"
listed "$WT/wo-$j-kappa" && die "FAIL W16: wo close kept a worktree whose only ignored folder is disposable" "$out"
y="$(open "Lambda")"; $W start "$y" >/dev/null 2>&1 || die "wo start failed"
mkdir -p "$WT/wo-$y-lambda/app/node_modules/x" && printf 'x\n' > "$WT/wo-$y-lambda/app/node_modules/x/i.js" && printf 'SECRET=2\n' > "$WT/wo-$y-lambda/app/.env"
$W verify "$y" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$y" 2>&1)" || die "FAIL W16: wo close failed" "$out"
{ [ -f "$WT/wo-$y-lambda/app/.env" ] && printf '%s\n' "$out" | grep -qF "WO-$y: worktree $WT/wo-$y-lambda kept: it holds files git ignores (app/.env)"; } \
  || die "FAIL W16: wo close did not keep a worktree with app/.env beside a disposable folder, naming app/.env alone" "$out"
# a folder on the list that git does not ignore itself (target/: new-project's .gitignore ignores dist/, build/
# and coverage/, not it), holding only an ignored .env, is reported whole (target/): it is not disposable, so
# the worktree is kept and target/ named
v="$(open "Nu")"; $W start "$v" >/dev/null 2>&1 || die "wo start failed"
mkdir -p "$WT/wo-$v-nu/target" && printf 'SECRET=3\n' > "$WT/wo-$v-nu/target/.env"
$W verify "$v" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$v" 2>&1)" || die "FAIL W16: wo close failed" "$out"
{ [ -f "$WT/wo-$v-nu/target/.env" ] && printf '%s\n' "$out" | grep -qF "WO-$v: worktree $WT/wo-$v-nu kept: it holds files git ignores (target/)"; } \
  || die "FAIL W16: wo close removed a target/ that git does not ignore, holding a .env" "$out"

# W17: a gitlink in the worktree's index without a .gitmodules is a submodule too: the worktree is kept
g="$(open "Xi")"; $W start "$g" >/dev/null 2>&1 || die "wo start failed"
{ mkdir "$WT/wo-$g-xi/vendored" && G -C "$WT/wo-$g-xi" update-index --add --cacheinfo "160000,$(G rev-parse HEAD),vendored" \
  && G -C "$WT/wo-$g-xi" commit -qm "WO-$g gitlink" && G merge -q --ff-only "wo/$g-xi"; } >/dev/null 2>&1 || die "could not commit a gitlink"
[ ! -e "$WT/wo-$g-xi/.gitmodules" ] || die "the worktree has a .gitmodules; W17 needs none"
$W verify "$g" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$g" 2>&1)" || die "FAIL W17: wo close failed" "$out"
{ listed "$WT/wo-$g-xi" && printf '%s\n' "$out" | grep -qF "WO-$g: worktree $WT/wo-$g-xi kept: it holds submodules"; } \
  || die "FAIL W17: wo close removed a worktree holding a gitlink without a .gitmodules" "$out"
{ G rm -q --cached vendored && rmdir vendored && G commit -qm "drop the gitlink"; } >/dev/null 2>&1 || die "could not drop the gitlink"   # W15 needs a clean .gitmodules

# W18: status.showUntrackedFiles=no hides nothing from close: an untracked notes.txt and an ignored .env keep it
q="$(open "Omicron")"; $W start "$q" >/dev/null 2>&1 || die "wo start failed"
printf 'n\n' > "$WT/wo-$q-omicron/notes.txt"; printf 'SECRET=4\n' > "$WT/wo-$q-omicron/.env"
$W verify "$q" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
G config status.showUntrackedFiles no || die "could not set status.showUntrackedFiles"
rc=0; out="$(ALLOW_PLACEHOLDERS=1 $W close "$q" 2>&1)" || rc=$?
G config --unset status.showUntrackedFiles
{ [ "$rc" -eq 0 ] && [ -f "$WT/wo-$q-omicron/notes.txt" ] && [ -f "$WT/wo-$q-omicron/.env" ] && listed "$WT/wo-$q-omicron" \
  && printf '%s\n' "$out" | grep -qF "WO-$q: worktree $WT/wo-$q-omicron kept: it holds uncommitted work (notes.txt)"; } \
  || die "FAIL W18: under status.showUntrackedFiles=no wo close did not keep a worktree holding untracked and ignored files" "$out"

# W19: an order whose documents are not committed is not started: its branch would not hold them
r="$($W new "Pi" --size small 2>/dev/null | grep -o 'WO-[0-9]*' | head -1 | sed 's/^WO-//')"
rc=0; out="$($W start "$r" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "refusing to start WO-$r: its documents are not committed; commit WO-$r's documents first" \
  && ! listed "$WT/wo-$r-pi" && ! grep -q '^status=in-progress' Workspace/Docs/WorkOrders/WO-"$r"-pi/.wo-meta; } \
  || die "FAIL W19: wo start started an order whose documents are not committed" "$out"
{ G add -A Workspace/Docs/WorkOrders && G commit -qm "WO-$r open"; } >/dev/null 2>&1 || die "could not commit WO-$r"

# W20: wo verify and wo close inside a worktree refuse, naming the main checkout, and change nothing
c="$(open "Rho")"; $W start "$c" >/dev/null 2>&1 || die "wo start failed"
for cmd in verify close; do
  rc=0; out="$(cd "$WT/wo-$c-rho" && ./.aicodepipeline/bin/wo "$cmd" "$c" 2>&1)" || rc=$?
  { [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "refusing to $cmd WO-$c here: this is an order's worktree" \
    && printf '%s\n' "$out" | grep -qF "run wo $cmd in the main checkout ($P)"; } || die "FAIL W20: wo $cmd inside the worktree did not refuse, naming the main checkout" "$out"
done
[ -z "$(G -C "$WT/wo-$c-rho" status --porcelain --untracked-files=normal)" ] || die "FAIL W20: a refused command changed the worktree" "$(G -C "$WT/wo-$c-rho" status --porcelain)"

# W23: a project that itself lives in a linked worktree (not an order's) verifies and closes its orders as before
w="$(open "Upsilon")"; G worktree add -q --detach "$EVAL_TMP/side" HEAD || die "could not add the side worktree"
mkdir -p "$EVAL_TMP/side/s" && cp s/ok.sh "$EVAL_TMP/side/s/ok.sh"
out="$(cd "$EVAL_TMP/side" && ./.aicodepipeline/bin/wo verify "$w" --run s/ok.sh 2>&1)" || die "FAIL W23: wo verify refused in a project that lives in a linked worktree" "$out"
out="$(cd "$EVAL_TMP/side" && ALLOW_PLACEHOLDERS=1 ./.aicodepipeline/bin/wo close "$w" 2>&1)" || die "FAIL W23: wo close refused in a project that lives in a linked worktree" "$out"
ls "$EVAL_TMP"/side/Workspace/Docs/WorkOrders/WO-"$w"-*/WO-"$w"-CLOSEOUT.md >/dev/null 2>&1 || die "FAIL W23: no closeout in the linked worktree's project" "$out"

# W21: a file git is told not to look at (skip-worktree; assume-unchanged) keeps a merged, clean-looking worktree
for f in skip-worktree assume-unchanged; do
  v="$(open "Sigma $f")"; $W start "$v" >/dev/null 2>&1 || die "wo start failed"
  { G -C "$WT/wo-$v-sigma-$f" update-index "--$f" src/a.ts && printf 'changed\n' > "$WT/wo-$v-sigma-$f/src/a.ts"; } || die "could not mark src/a.ts"
  $W verify "$v" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
  out="$(ALLOW_PLACEHOLDERS=1 $W close "$v" 2>&1)" || die "FAIL W21: wo close failed" "$out"
  { listed "$WT/wo-$v-sigma-$f" && printf '%s\n' "$out" | grep -qF "kept: git is told not to look at some of its files"; } \
    || die "FAIL W21: wo close removed a worktree with a $f file" "$out"
done

# W22: a closed order is not started again (Alpha closed in W5)
rc=0; out="$($W start "$n" 2>&1)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "refusing to start WO-$n: it is closed"; } || die "FAIL W22: wo start started a closed order" "$out"

# W15: a worktree holding an initialised submodule is kept: its commits may exist nowhere else
mkdir -p "$EVAL_TMP/lib" && G -C "$EVAL_TMP/lib" init -q && printf 'l\n' > "$EVAL_TMP/lib/l.txt" && G -C "$EVAL_TMP/lib" add -A && G -C "$EVAL_TMP/lib" commit -qm lib || die "could not make the submodule's repository"
{ G -c protocol.file.allow=always submodule add -q "$EVAL_TMP/lib" lib && G commit -qm "add lib"; } >/dev/null 2>&1 || die "could not add the submodule"
u="$(open "Mu")"; $W start "$u" >/dev/null 2>&1 || die "wo start failed"
G -c protocol.file.allow=always -C "$WT/wo-$u-mu" submodule update --init -q >/dev/null 2>&1 || die "could not initialise the submodule in the worktree"
{ printf 'm\n' > "$WT/wo-$u-mu/lib/m.txt" && G -C "$WT/wo-$u-mu/lib" add -A && G -C "$WT/wo-$u-mu/lib" commit -qm "unpushed"; } || die "could not commit in the submodule"
G -C "$WT/wo-$u-mu" add lib && G -C "$WT/wo-$u-mu" commit -qm "WO-$u bump lib" && G merge -q --ff-only "wo/$u-mu" || die "could not merge the submodule bump"
$W verify "$u" --run s/ok.sh >/dev/null 2>&1 || die "wo verify failed"
out="$(ALLOW_PLACEHOLDERS=1 $W close "$u" 2>&1)" || die "FAIL W15: wo close failed" "$out"
{ [ -f "$WT/wo-$u-mu/lib/m.txt" ] && listed "$WT/wo-$u-mu"; } || die "FAIL W15: wo close removed a worktree holding a submodule" "$out"
printf '%s\n' "$out" | grep -qF "WO-$u: worktree $WT/wo-$u-mu kept: it holds submodules" || die "FAIL W15: wo close did not say the worktree holds submodules" "$out"

# W9: outside git, wo start still marks the order in progress and says there is no worktree
cd "$EVAL_TMP" && "$PIPELINE_ROOT/bin/new-project" q --name Q --no-git >/dev/null 2>&1 && cd q || die "new-project failed"
q="$(./.aicodepipeline/bin/wo new "Plain" --size small 2>/dev/null | grep -o 'WO-[0-9]*' | head -1)"; q="${q#WO-}"
out="$(./.aicodepipeline/bin/wo start "$q" 2>&1)" || die "FAIL W9: wo start failed outside git" "$out"
printf '%s\n' "$out" | grep -qxF "WO-$q: no worktree: not a git repository with a commit" || die "FAIL W9: wo start outside git did not say there is no worktree" "$out"
echo "worktree-lifecycle: all checks passed"
exit 0
