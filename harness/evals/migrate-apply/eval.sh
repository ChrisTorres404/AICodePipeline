#!/usr/bin/env bash
# acp migrate apply restructures a project into acp/ (the pipeline) and app/ (the product) as one commit, from an ACP
# source clone of the project's own version, only for the answered plan written for it with a backup that checks
# whole; it refuses with one line before touching anything otherwise; a failure before the install puts every step
# back exactly; a failure from the install on stops with the way back; nothing of the owner's is swept into the commit.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.name t && git config --global user.email t@example.com && git config --global init.defaultBranch main \
  && git config --global filter.lfs.clean "git-lfs clean -- %f" || { echo "FAIL setup: git identity"; exit 1; }   # a global driver no file uses must not stop apply
run() { perl -e 'alarm 300; exec @ARGV' "$@"; }
# one project made the way users make them, then a fresh copy (and its own plan, backup and answers) per case
BASE="$EVAL_TMP/base"
run "$PIPELINE_ROOT/bin/new-project" "$BASE/proj" --name Proj >"$EVAL_TMP/np.log" 2>&1 || { echo "FAIL setup: new-project: $(tail -1 "$EVAL_TMP/np.log")"; exit 1; }
( cd "$BASE/proj" && mkdir -p src docs vendor fixtures && printf 'print(1)\n' > src/main.py && printf '# Proj\n' > README.md && printf 'd\n' > docs/d.md \
  && printf 'x\n' > src/build.log && printf 'vendor/\n' >> .gitignore && printf 'lib\n' > vendor/lib.js && printf 'f\n' > fixtures/sample.log \
  && printf 'h\n' > HANDOFF-2026-01-01.md && printf '*.tmp\n' >> .gitignore && printf 'kept\n' > 'src/[ab].tmp' && printf 'SECRET=1\n' > src/a.tmp \
  && git add src/main.py README.md docs .gitignore HANDOFF-2026-01-01.md && git add -f vendor/lib.js fixtures/sample.log && git --literal-pathspecs add -f 'src/[ab].tmp' && git commit -qm product \
  && run "$PIPELINE_ROOT/bin/wo" new "Paths order" --paths src >/dev/null 2>&1 && git add -A && git commit -qm order \
  && git init -q --bare "$BASE/remote.git" && git remote add origin "$BASE/remote.git" && git push -q -u origin main 2>/dev/null ) || { echo "FAIL setup: product"; exit 1; }
CASE=""
fresh() { # <case>: a copy of the base project at $P (the last case's copy removed first: each is ~45 MB), unplanned
  if [ -n "$CASE" ]; then chmod -R u+rwx "$EVAL_TMP/$CASE" 2>/dev/null; rm -rf "${EVAL_TMP:?}/$CASE" "${EVAL_TMP:?}/acp-$CASE"; fi; CASE="$1"
  P="$EVAL_TMP/$1/proj"; rm -rf "$EVAL_TMP/$1"; mkdir -p "$EVAL_TMP/$1" && cp -R "$BASE/proj" "$P" && cp -R "$BASE/remote.git" "$EVAL_TMP/$1/remote.git" \
    && git -C "$P" remote set-url origin "$EVAL_TMP/$1/remote.git" || { echo "FAIL setup: copy $1"; exit 1; }; }
plan() { # plan, back up and answer every question with its suggestion (or by $ANS: "n value ...")
  ( cd "$P" && run "$ACP" migrate plan >/dev/null 2>&1 && mkdir -p "$P.bk" && run "$ACP" migrate backup --to "$P.bk" >/dev/null 2>&1 ) || { echo "FAIL setup: plan or backup in $P"; exit 1; }
  "$PY" -c 'import json, sys; [print(q["n"], q["suggested"]) for q in json.load(open(sys.argv[1]))["questions"]]' "$P/.acp-migration/moves.json" | while read -r n v; do
    ( cd "$P" && run "$ACP" migrate answer "$n" "$v" >/dev/null 2>&1 ) || { echo "FAIL setup: answer $n"; exit 1; }; done; }
snap() { "$PY" - "$P" <<'PYEOF'
import hashlib, os, sys
top = sys.argv[1]; h = hashlib.sha256()
for d, dirs, files in os.walk(top):
    dirs.sort(); rel = os.path.relpath(d, top)
    if rel.split(os.sep)[0] == ".acp-migration": continue
    st = os.lstat(d); h.update(f"D {rel} {st.st_mode} {st.st_mtime_ns}\n".encode())
    for f in sorted(files):
        p = os.path.join(d, f); st = os.lstat(p)
        data = os.readlink(p).encode() if os.path.islink(p) else open(p, "rb").read()
        h.update(f"F {os.path.join(rel, f)} {st.st_mode} {st.st_mtime_ns} ".encode() + hashlib.sha256(data).digest())
print(h.hexdigest())
PYEOF
}
refused() { # <case> <expected line> [acp]: apply refuses with exactly that line, and nothing in the project changes
  local c="$1" want="$2" a="${3:-$ACP}" s0; s0="$(snap)"; out="$(cd "$P" && run "$a" migrate apply 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qxF -- "$want" <<< "$out" && [ "$(snap)" = "$s0" ]; } || { echo "FAIL $c: expected exit 1 and '$want', nothing changed (exit $rc): $out"; exit 1; }; }

# P1 (the base failure): a planned, backed-up, answered project is restructured as one commit
fresh p1 && NO="$(ls "$P/Workspace/Docs/WorkOrders" | sed -n 's/^WO-\([0-9]*\)-paths-order$/\1/p')" \
  && (cd "$P" && run .aicodepipeline/bin/wo start "$NO" >/dev/null 2>&1) && git -C "$P" add -A && git -C "$P" commit -qm started && git -C "$P" push -q 2>/dev/null \
  && WT="$(sed -n 's/^worktree=//p' "$P"/Workspace/Docs/WorkOrders/WO-*paths-order/.wo-meta)" && [ -d "$P/$WT" ] || { echo "FAIL setup: wo start made no worktree"; exit 1; }
plan && RP="$(cd "$P" && pwd -P)"
git -C "$P" ls-tree -r HEAD > "$EVAL_TMP/p1-before.tree"
H0="$(git -C "$P" rev-parse HEAD)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "^acp migrate apply: 8 moves, the layout and the install committed as [0-9a-f]\{12\} (Move the product into app/ and the pipeline into acp/), without hooks\.$" <<< "$out"; } \
  || { echo "FAIL P1: apply did not restructure the project"; echo "  (exit $rc) $out"; exit 1; }
# P2: the layout, one commit on the old one, a clean tree, working tools
{ [ "$(git -C "$P" rev-list --count "$H0..HEAD")" = 1 ] && [ -z "$(git --no-optional-locks -C "$P" status --porcelain)" ] \
  && [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr '\n' ' ')" = ".acp-migration .claude .git .gitignore AGENTS.md CLAUDE.md README.md acp app pipeline.config.sh " ] \
  && [ "$(ls -A "$P/acp" | LC_ALL=C sort | tr '\n' ' ')" = ".aicodepipeline Workspace playbooks " ] && [ "$(ls -A "$P/app" | LC_ALL=C sort | tr '\n' ' ')" = "docs fixtures src vendor " ]; } \
  || { echo "FAIL P2: the project is not one clean commit in the acp/ + app/ layout: $(cd "$P" && ls -A | tr '\n' ' ') / $(git --no-optional-locks -C "$P" status --porcelain | head -3)"; exit 1; }
{ [ "$(cd "$P" && run acp/.aicodepipeline/bin/playbook where 2>&1)" = "$RP/acp/playbooks" ] && [ ! -e "$P/acp/.aicodepipeline/playbooks" ]; } || { echo "FAIL P2: the playbooks did not move to acp/playbooks"; exit 1; }
grep -q '^export CODE_DIR="app"' "$P/pipeline.config.sh" && grep -qxF '.acp-migration/' "$P/.gitignore" || { echo "FAIL P2: the config or .gitignore does not state the layout"; exit 1; }
"$PY" -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if r["outcome"] == "done" and r["commit"] and r["indexes"] else 1)' "$P/.acp-migration/applied.json" || { echo "FAIL P2: applied.json does not record a finished apply"; exit 1; }
# P1b: every file tracked before is tracked after, the same blob and mode at its new place (the install's own aside);
# a tracked file now ignored there (a force-added vendor file, a tracked log) is kept; the handoff, sorting before
# Workspace, reached its archive
git -C "$P" ls-tree -r HEAD > "$EVAL_TMP/p1-after.tree"
"$PY" - "$EVAL_TMP/p1-before.tree" "$EVAL_TMP/p1-after.tree" <<'PYEOF' || { echo "FAIL P1b: a file tracked before is missing, or changed, after apply"; exit 1; }
import sys
row = lambda l: (l.split("\t", 1)[1], tuple(l.split("\t", 1)[0].split()[0::2]))
before = dict(row(l) for l in open(sys.argv[1]).read().splitlines()); after = dict(row(l) for l in open(sys.argv[2]).read().splitlines())
moves = [("HANDOFF-2026-01-01.md", "acp/Workspace/Sessions/archive/HANDOFF-2026-01-01.md"), ("src/", "app/src/"), ("docs/", "app/docs/"),
         ("vendor/", "app/vendor/"), ("fixtures/", "app/fixtures/"), ("Workspace/", "acp/Workspace/")]
own = (".aicodepipeline/", ".claude/", "AGENTS.md", "CLAUDE.md", "pipeline.config.sh", ".gitignore")
for p, v in before.items():
    if p.startswith(own) or p.endswith(("/.wo-manifest", "/.wo-meta")): continue
    q = next((d + p[len(s):] for s, d in moves if p == s or p.startswith(s)), p)
    if after.get(q) != v: print("  missing or changed:", p, "->", q); sys.exit(1)
PYEOF
# P1c: the order's worktree moved with its folder, git's record of it repaired, and the order's record of it mapped
{ [ -z "$(git -C "$P" worktree list --porcelain | grep '^prunable')" ] && git -C "$P" worktree list --porcelain | grep -qxF "worktree $RP/acp/$WT" \
  && grep -qxF "worktree=acp/$WT" "$P"/acp/Workspace/Docs/WorkOrders/WO-*paths-order/.wo-meta && grep -qxF "worktree_pre_migration=$WT" "$P"/acp/Workspace/Docs/WorkOrders/WO-*paths-order/.wo-meta; } \
  || { echo "FAIL P1c: the order's worktree was not repaired at its new place, or its record not mapped"; exit 1; }
# P1d: the .gitignore the install keeps in the work-order and bug folders is at its new place, its content unchanged
for f in WorkOrders Bugs; do
  [ "$(git -C "$P" show "$H0:Workspace/Docs/$f/.gitignore" 2>/dev/null)" = "$(cat "$P/acp/Workspace/Docs/$f/.gitignore")" ] || { echo "FAIL P1d: Workspace/Docs/$f/.gitignore did not reach acp/ as it was"; exit 1; }
done
# P3: an ignored file travels with its folder and stays out of git; a tracked file named like a pattern (src/[ab].tmp)
# brings in nothing but itself: the ignored src/a.tmp beside it, which holds a secret, is never staged or stored
{ [ -f "$P/app/src/build.log" ] && [ -z "$(git -C "$P" ls-files app/src/build.log)" ] && [ -f "$P/app/src/a.tmp" ] \
  && [ "$(git -C "$P" --literal-pathspecs ls-files 'app/src/a.tmp' 'app/src/[ab].tmp')" = "app/src/[ab].tmp" ] \
  && ! git -C "$P" cat-file --batch-all-objects --batch-check='%(objectname)' | grep -qxF "$(git -C "$P" hash-object "$P/app/src/a.tmp")"; } \
  || { echo "FAIL P3: an ignored file did not travel with its folder, or was committed or stored"; exit 1; }
# P7: an open order's manifest and declared paths are mapped; the originals are kept
O="$(ls -d "$P"/acp/Workspace/Docs/WorkOrders/WO-*paths-order* | head -1)"
{ grep -q "	app/src/main.py$" "$O/.wo-manifest" && ! grep -q "	src/main.py$" "$O/.wo-manifest" && [ ! -e "$O/.wo-manifest.pre-migration" ] \
  && "$PY" -c 'import base64, json, sys; s = [x for x in map(json.loads, open(sys.argv[1])) if x.get("kind") == "edit" and x["path"].endswith("paths-order/.wo-manifest")]; sys.exit(0 if len(s) == 1 and "\tsrc/main.py\n" in base64.b64decode(s[0]["before"]).decode() else 1)' "$P/.acp-migration/journal.jsonl" \
  && grep -qxF "paths=app/src" "$O/.wo-meta" && grep -qxF "paths_pre_migration=src" "$O/.wo-meta"; } || { echo "FAIL P7: an open order's manifest or declared paths were not mapped, or the originals not kept"; exit 1; }
# P1e: the migrated project, its open order and that order's worktree included, is in order by the structure rule
out="$(cd "$P" && python3 acp/.aicodepipeline/core/hooks/layout.py --root "$P" 2>&1)" || { echo "FAIL P1e: the structure rule finds the migrated project out of order: $out"; exit 1; }
# P8: the commit ran without hooks (a hook that always fails was in place)
fresh p8 && printf '#!/bin/sh\nexit 1\n' > "$P/.git/hooks/pre-commit" && chmod +x "$P/.git/hooks/pre-commit" && plan
( cd "$P" && run "$ACP" migrate apply >/dev/null 2>&1 ) || { echo "FAIL P8: a failing pre-commit hook stopped the restructure commit"; exit 1; }

# P4: each refusal before anything moves, one line, nothing changed
fresh p4 && plan; RP="$(cd "$P" && pwd -P)"
cp "$P/.acp-migration/moves.json" "$EVAL_TMP/p4-moves.json"
QC="$("$PY" -c 'import json, sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q["options"] == ["commit", "pinned"]][0])' "$P/.acp-migration/moves.json")"
setq() { "$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); [q.update(answer=None if sys.argv[3] == "-" else sys.argv[3]) for q in d["questions"] if q["n"] == int(sys.argv[2])]; json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)' "$P/.acp-migration/moves.json" "$1" "$2"; }
setq "$QC" -
refused P4 "acp migrate apply: question $QC has no answer: acp migrate answer $QC <option> (MIGRATION-PLAN.md lists them)"
setq "$QC" pinned
refused P4 "acp migrate apply: question $QC: a pipeline installed from a pinned release is not supported by apply yet; answer commit"
setq "$QC" COMMIT
refused P4 "acp migrate apply: question $QC is answered 'COMMIT', which is not one of its options; answer it again"
setq "$QC" commit; "$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); d["entries"][0]["to"] = "x"; json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)' "$P/.acp-migration/moves.json"
refused P4 "acp migrate apply: moves.json and MIGRATION-PLAN.md are not the same plan (an edit, or a file from another run); run: acp migrate plan --replace"
cp "$EVAL_TMP/p4-moves.json" "$P/.acp-migration/moves.json"
refused P4 "acp migrate apply: apply runs from an ACP source clone outside the project, not from an installed copy ($RP/.aicodepipeline); run it as <clone>/bin/acp migrate apply" "$P/.aicodepipeline/bin/acp"
fresh p4b && printf 'u\n' > "$P/untracked.txt" && plan
refused P4 "acp migrate apply: the repository has changes apply would sweep into its commit: untracked.txt; commit or set them aside, then plan again"
fresh p4c && plan && printf 'x\n' >> "$P/README.md"
refused P4 "acp migrate apply: the project has changed since the backup: README.md"
fresh p4d && mkdir -p "$P/app" && printf 'a\n' > "$P/app/a.txt" && git -C "$P" add app && git -C "$P" commit -qm app && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: the repository already has app at its top; rename it, commit, and plan again"
fresh p4e && printf 'export CODE_DIR="."\n' >> "$P/pipeline.config.sh" && git -C "$P" commit -qam twice && git -C "$P" push -q 2>/dev/null && plan
s0="$(snap)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q "^acp migrate apply: acp layout: .*CODE_DIR" <<< "$out" && [ "$(snap)" = "$s0" ]; } || { echo "FAIL P4: a config acp layout refuses was not refused before anything moved (exit $rc): $out"; exit 1; }
fresh p4f && printf '1.0.0\n' > "$P/.aicodepipeline/VERSION" && git -C "$P" commit -qam old && git -C "$P" push -q 2>/dev/null && plan
V="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$PIPELINE_ROOT/bin/acp")"; RPR="$(cd "$PIPELINE_ROOT" && pwd -P)"
refused P4 "acp migrate apply: upgrade first: $RPR/bin/install.sh $(cd "$P" && pwd -P), commit, then acp migrate plan again (this project's pipeline is 1.0.0, this ACP is $V; one change per commit: upgrade, then plan, backup, answer, apply)"
fresh p4g && printf '*.bin filter=x\n' > "$P/.gitattributes" && printf 'b' > "$P/a.bin" && git -C "$P" add .gitattributes a.bin && git -C "$P" commit -qm filtered && git -C "$P" push -q 2>/dev/null && git -C "$P" config filter.x.clean cat && plan
# the scopes as migrate sees them: it drops every GIT_* variable (a runner's GIT_CONFIG_SYSTEM or GIT_CONFIG_PARAMETERS too)
SC="$(env $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/-u \1/p') git -C "$P" config --show-scope --get-regexp '^filter\.' | awk '{print $1}' | LC_ALL=C sort -u | paste -sd, - | sed 's/,/, /g')"
case ", $SC," in *", global,"*) ;; *) echo "FAIL setup: the filter driver set globally here is not seen ($SC)"; exit 1;; esac   # a runner may add its own system ones (Ubuntu's git-lfs)
case ", $SC," in *", local,"*) ;; *) echo "FAIL setup: the filter driver set in the repository is not seen ($SC)"; exit 1;; esac
for x in $(printf '%s' "$SC" | tr -d ' ' | tr ',' ' '); do case "$x" in system|global|local) ;; *) echo "FAIL setup: a filter driver scope git should not report here: $x ($SC)"; exit 1;; esac; done
refused P4 "acp migrate apply: a.bin passes through a filter driver (configured: $SC); apply stages files as they are on disk, so a filtered file would be committed unfiltered: move this repository by hand"
fresh p4h && plan && mkdir -p "$EVAL_TMP/noid" && printf '[user]\n\tuseConfigOnly = true\n' > "$EVAL_TMP/noid/.gitconfig"   # the identity is global only
s0="$(snap)"; out="$(cd "$P" && HOME="$EVAL_TMP/noid" run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate apply: git has no name and email for the commit: set user.name and user.email first" <<< "$out" && [ "$(snap)" = "$s0" ]; } \
  || { echo "FAIL P4: no git identity was not refused before anything moved (exit $rc): $out"; exit 1; }
fresh p4i && plan && printf '{}\n' > "$P/.acp-migration/journal.jsonl"
refused P4 "acp migrate apply: an apply has run here (.acp-migration/journal.jsonl); its record names no backup: restore the project from your own copy"
A4="$(ls "$P.bk"/*.tar | head -1)"; RPA="$(cd "$P" && pwd -P)"; printf '{"backup_archive": "%s", "outcome": "started"}\n' "$A4" > "$P/.acp-migration/applied.json"
refused P4 "acp migrate apply: an apply has run here (.acp-migration/journal.jsonl); restore by hand: mkdir $RPA.restored && tar -xpf $A4 -C $RPA.restored, then move $RPA aside and $RPA.restored into its place"
fresh p4n && mkdir -p "$P/Workspace/Sessions/archive" && printf 'other\n' > "$P/Workspace/Sessions/archive/HANDOFF-2026-01-01.md" && git -C "$P" add -A && git -C "$P" commit -qm clash && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: \`HANDOFF-2026-01-01.md\` would move to \`acp/Workspace/Sessions/archive/HANDOFF-2026-01-01.md\`, where \`Workspace/Sessions/archive/HANDOFF-2026-01-01.md\` already is; apply never moves anything over it: move one aside, commit, and plan again"
fresh p4p && mkdir -p "$P/docs/old/WO-0001-other" && printf 's\n' > "$P/docs/old/WO-0001-other/WO-0001-SPEC.md" && git -C "$P" add docs && git -C "$P" commit -qm stray && git -C "$P" push -q 2>/dev/null && plan
QS="$("$PY" -c 'import json, sys; print([e["question"] for e in json.load(open(sys.argv[1]))["entries"] if e["kind"] == "stray-order"][0])' "$P/.acp-migration/moves.json")" \
  && (cd "$P" && run "$ACP" migrate answer "$QS" import >/dev/null 2>&1) || { echo "FAIL setup: the stray order was not planned, or not answered import"; exit 1; }
OLD1="$(cd "$P/Workspace/Docs/WorkOrders" && ls -d WO-0001-* | head -1)"
refused P4 "acp migrate apply: \`docs/old/WO-0001-other\` is WO-0001, and \`Workspace/Docs/WorkOrders/$OLD1\` already has that number; answer app, or renumber one, commit, and plan again"
fresh p4o && ln -s ../README.md "$P/src/link-up" && ln -s main.py "$P/src/link-in" && git -C "$P" add src && git -C "$P" commit -qm links && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: these links would point at the wrong place after the moves, and apply does not rewrite links: src/link-up; change them to work from both places, commit, and plan again"
fresh p4j && printf 'n\n' > "$P/new.txt" && git -C "$P" add new.txt && git -C "$P" commit -qm unpushed && plan
s0="$(snap)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q "^acp migrate apply: the plan has a blocker: the current branch has 1 commit(s) not pushed" <<< "$out" && [ "$(snap)" = "$s0" ]; } \
  || { echo "FAIL P4: an unpushed commit was not refused (exit $rc): $out"; exit 1; }
fresh p4k && mkdir -p "$EVAL_TMP/p4k/outside" && ln -s "$EVAL_TMP/p4k/outside" "$P/.vscode" && git -C "$P" add .vscode && git -C "$P" commit -qm link && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: question 1 is answered 'stop the migration'"

fresh p4l && O="$(ls -d "$P"/Workspace/Docs/WorkOrders/WO-*paths-order* | head -1)" && printf 'paths_pre_migration=x\n' >> "$O/.wo-meta" && git -C "$P" add -A && git -C "$P" commit -qm kept && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: ${O#"$P"/} already holds what apply keeps of its old paths (paths_pre_migration= or worktree_pre_migration= in .wo-meta); move that aside first"
fresh p4m && O="$(ls -d "$P"/Workspace/Docs/WorkOrders/WO-*paths-order* | head -1)" && printf 'no tab here\n' >> "$O/.wo-manifest" && git -C "$P" commit -qam odd && git -C "$P" push -q 2>/dev/null && plan
refused P4 "acp migrate apply: ${O#"$P"/}/.wo-manifest has a line that is not '<hash><tab><path>'; open orders are rewritten line by line, so fix it first"

# P5: a failure before the install puts every step back exactly: the backup checks against the project again, and a
# second apply, once the cause is gone, finishes
fresh p5 && plan
if [ "$(id -u)" = 0 ]; then echo "note: P5 skipped: running as root, so a read-only folder does not stop the first step"; else
chmod 555 "$P"   # the project folder itself is not in the backup's manifest: the first step fails on it
out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?; chmod 755 "$P"
{ [ "$rc" -eq 1 ] && grep -q "every move was put back and nothing was committed; fix that, then run apply again$" <<< "$out"; } || { echo "FAIL P5: a failed step did not stop with the put-back line (exit $rc): $out"; exit 1; }
( cd "$P" && run "$ACP" migrate backup --check >/dev/null 2>&1 ) || { echo "FAIL P5: after the put-back the project is not as the backup holds it: $(cd "$P" && "$ACP" migrate backup --check 2>&1)"; exit 1; }
{ [ -z "$(git --no-optional-locks -C "$P" status --porcelain -- . ':(exclude).acp-migration')" ] && [ ! -e "$P/acp" ] && [ ! -e "$P/app" ] && ls "$P/.acp-migration/" | grep -q "^journal-put-back-.*\.jsonl$"; } || { echo "FAIL P5: the put-back left the tree changed, or the journal not set aside"; exit 1; }
( cd "$P" && run "$ACP" migrate apply >/dev/null 2>&1 ) || { echo "FAIL P5: apply did not finish once the cause was gone"; exit 1; }
fi
# P5b: a file a .gitignore pattern ignored only at its old place is refused, and every move put back. The plan offers the
# line that keeps it ignored (its .gitignore question, which must be there); answered no here, apply's own check is what
# is tested
fresh p5b && mkdir -p "$P/out" && printf 'b\n' > "$P/out/bundle.js" && printf '/out\n' >> "$P/.gitignore" && git -C "$P" commit -qam out && git -C "$P" push -q 2>/dev/null && plan
gq="$("$PY" -c 'import json, sys; print((json.load(open(sys.argv[1])).get("gitignore_add") or {}).get("question", ""))' "$P/.acp-migration/moves.json")"
{ [ -n "$gq" ] && ( cd "$P" && run "$ACP" migrate answer "$gq" no >/dev/null 2>&1 ); } || { echo "FAIL setup: P5b's plan offered no .gitignore line, or its question could not be answered no"; exit 1; }
out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "after the moves git no longer ignores app/out/bundle.js: a .gitignore pattern names their old place. Add one for the new place (app/…), commit, take a new backup, and plan again" <<< "$out" \
  && ( cd "$P" && run "$ACP" migrate backup --check >/dev/null 2>&1 ); } || { echo "FAIL P5b: a newly un-ignored file was not refused with everything put back (exit $rc): $out"; exit 1; }

# P6: a failure from the install on stops with both ways back, and the by-hand one, run as printed, restores the project
fresh p6 && plan && BROKEN="$EVAL_TMP/acp-p6" && cp -R "$PIPELINE_ROOT" "$BROKEN" && printf '#!/usr/bin/env bash\necho "install: broken on purpose" >&2; exit 1\n' > "$BROKEN/bin/install.sh"
out="$(cd "$P" && run "$BROKEN/bin/acp" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q "^acp migrate apply: the moves are done and the install failed (install: broken on purpose); restore by hand: mkdir " <<< "$out"; } \
  || { echo "FAIL P6: a failed install did not stop with the way back (exit $rc): $out"; exit 1; }
"$PY" -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["outcome"] == "stopped at install" else 1)' "$P/.acp-migration/applied.json" || { echo "FAIL P6: applied.json does not say where apply stopped"; exit 1; }
cmd="$(sed -n 's/^.*restore by hand: \(mkdir .* -C [^,]*\), then move .*$/\1/p' <<< "$out")"
( eval "$cmd" ) && "$PY" - "$P.restored" "$P/.acp-migration/manifest.json" "$PIPELINE_ROOT/core/hooks" <<'PYEOF' || { echo "FAIL P6: the by-hand restore, run as printed, is not the project as backed up"; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[3]); import migrate
got, want = migrate.manifest_of(sys.argv[1]), json.load(open(sys.argv[2]))["entries"]
same = lambda a, b: {k: v for k, v in a.items() if k != "mtime_ns"} == {k: v for k, v in b.items() if k != "mtime_ns"} and abs(a["mtime_ns"] - b["mtime_ns"]) < 1000
sys.exit(0 if len(got) == len(want) and all(same(a, b) for a, b in zip(got, want)) else 1)   # PAX keeps times as a float: within 1 us
PYEOF

# P10: what the install leaves beyond its own files is never committed: a stray file, a new gitlink, a deletion apply
# did not plan; each stops at staging with the way back
wrapped() { # <case> <what the wrapped install also does, in the repository> <expected problem>
  fresh "$1" && plan && local A="$EVAL_TMP/acp-$1"; cp -R "$PIPELINE_ROOT" "$A" && mv "$A/bin/install.sh" "$A/bin/install.real" \
    && printf '#!/usr/bin/env bash\n"$(dirname "$0")/install.real" "$@" || exit 1\ncd "$1" && %s\n' "$2" > "$A/bin/install.sh" && chmod +x "$A/bin/install.sh" || { echo "FAIL setup: wrapped $1"; exit 1; }
  out="$(cd "$P" && run "$A/bin/acp" migrate apply 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF "acp migrate apply: staging the restructure found what apply did not make: $3" <<< "$out" && grep -qF "; nothing was committed; restore by hand: " <<< "$out" \
    && [ "$(git -C "$P" rev-list --count HEAD)" = "$(git -C "$BASE/proj" rev-list --count HEAD)" ]; } || { echo "FAIL P10: $3 was not stopped at staging (exit $rc): $out"; exit 1; }; }
wrapped p10a "printf s > STRAY.txt" "STRAY.txt (not tracked before, and not the install's)"
wrapped p10b "git init -q app/sub && printf x > app/sub/x && git -C app/sub add x && git -C app/sub -c user.name=t -c user.email=t@e commit -qm x" "app/sub (a new gitlink)"
wrapped p10c "rm README.md" "README.md (a deletion apply did not plan)"
wrapped p10d "grep -v '^.acp-migration/\$' .gitignore > .gi && mv .gi .gitignore" ".acp-migration/MIGRATION-PLAN.md (the plan folder)"
# P12: a failure at the layout step (after the moves, the edits and the worktree repair) puts every step back exactly
fresh p12 && NO="$(ls "$P/Workspace/Docs/WorkOrders" | sed -n 's/^WO-\([0-9]*\)-paths-order$/\1/p')" \
  && (cd "$P" && run .aicodepipeline/bin/wo start "$NO" >/dev/null 2>&1) && git -C "$P" add -A && git -C "$P" commit -qm started && git -C "$P" push -q 2>/dev/null || { echo "FAIL setup: p12 worktree"; exit 1; }   # the failure comes after the worktree repair
plan && A="$EVAL_TMP/acp-p12" && cp -R "$PIPELINE_ROOT" "$A" && mv "$A/bin/acp" "$A/bin/acp.real" \
  && { printf '#!/usr/bin/env bash\n'; grep '^VERSION=' "$A/bin/acp.real"; printf 'case "$*" in "layout --pipeline-dir"*) echo "layout: broken on purpose" >&2; exit 1;; esac\nexec "$(dirname "$0")/acp.real" "$@"\n'; } > "$A/bin/acp" \
  && chmod +x "$A/bin/acp" || { echo "FAIL setup: p12"; exit 1; }
out="$(cd "$P" && run "$A/bin/acp" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -q "^acp migrate apply: apply stopped (acp layout refused after its check passed: layout: broken on purpose); every move was put back and nothing was committed" <<< "$out" \
  && ( cd "$P" && run "$ACP" migrate backup --check >/dev/null 2>&1 ) && [ -z "$(git -C "$P" worktree list --porcelain | grep '^prunable')" ]; } \
  || { echo "FAIL P12: a failure at the layout step was not put back exactly (exit $rc): $out $(cd "$P" && "$ACP" migrate backup --check 2>&1)"; exit 1; }
# P11: apply waits for no one: while another acp migrate holds the plan folder's lock, it refuses and changes nothing
fresh p11 && plan; RP="$(cd "$P" && pwd -P)"
"$PY" -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(120)' "$P/.acp-migration" "$EVAL_TMP/held" & HOLD=$!
i=0; while [ ! -e "$EVAL_TMP/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
s0="$(snap)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?; kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate apply: another acp migrate is working in $RP/.acp-migration; wait for it to finish, then run this again" <<< "$out" && [ "$(snap)" = "$s0" ]; } \
  || { echo "FAIL P11: apply ran while another held the lock (exit $rc): $out"; exit 1; }

# P13: an interruption (SIGINT) in the put-back zone puts every step back exactly; one during the install stops with the
# way back and a record of where. Deterministic: a wrapped acp layout, or a wrapped install, waits for the signal.
blocking() { # <case> <what blocks: layout|install>: a copy of ACP whose layout step or install sleeps until killed, at $A
  A="$EVAL_TMP/acp-$1"; cp -R "$PIPELINE_ROOT" "$A" || return 1
  if [ "$2" = layout ]; then
    mv "$A/bin/acp" "$A/bin/acp.real" && { printf '#!/usr/bin/env bash\n'; grep '^VERSION=' "$A/bin/acp.real"; printf 'case "$*" in "layout --pipeline-dir"*) sleep 120; exit 1;; esac\nexec "$(dirname "$0")/acp.real" "$@"\n'; } > "$A/bin/acp"
  else printf '#!/usr/bin/env bash\nsleep 120\n' > "$A/bin/install.sh"; fi
  chmod +x "$A/bin/acp" "$A/bin/install.sh"; }
interrupt() { # <acp> <python test on the journal's steps that says when>: SIGINT apply then; prints its output
  "$PY" - "$P" "$1" "$2" <<'PYEOF'
import json, os, signal, subprocess, sys, time
p, acp, when = sys.argv[1:]
j = os.path.join(p, ".acp-migration", "journal.jsonl")
proc = subprocess.Popen([acp, "migrate", "apply"], cwd=p, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))   # a run started in the background inherits SIGINT ignored
end, sent = time.time() + 120, False
while time.time() < end and proc.poll() is None:
    try: steps = [x for x in (json.loads(l) for l in open(j) if l.endswith("\n")) if "kind" in x]   # a line being written is not read
    except (OSError, ValueError): steps = None
    if steps is not None and eval(when): time.sleep(0.5); proc.send_signal(signal.SIGINT); sent = True; break   # bin/acp execs python
    time.sleep(0.02)
out, _ = proc.communicate(timeout=300); print(f"rc={proc.returncode} sent={sent}"); print(out.strip())
PYEOF
}
fresh p13a && plan && blocking p13a layout || { echo "FAIL setup: p13a"; exit 1; }
out="$(interrupt "$A/bin/acp" 'any(x["kind"] == "layout" for x in steps)')"
{ grep -qx "rc=1 sent=True" <<< "$out" && grep -q "every move was put back and nothing was committed" <<< "$out" && ( cd "$P" && run "$ACP" migrate backup --check >/dev/null 2>&1 ); } \
  || { echo "FAIL P13: an interruption in the put-back zone was not put back exactly: $out"; exit 1; }
fresh p13b && plan && blocking p13b install || { echo "FAIL setup: p13b"; exit 1; }
out="$(interrupt "$A/bin/acp" 'any(x["kind"] == "install" for x in steps)')"
{ grep -qx "rc=1 sent=True" <<< "$out" && grep -q "; restore by hand: mkdir " <<< "$out" \
  && "$PY" -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["outcome"] == "stopped at install" else 1)' "$P/.acp-migration/applied.json"; } \
  || { echo "FAIL P13: an interruption during the install left no record of where, or no way back: $out"; exit 1; }

# P14: a project with no bug folder: the install makes acp/Workspace/Docs/Bugs/.gitignore during apply, and the commit
# takes it as the install's own
fresh p14 && git -C "$P" rm -rq Workspace/Docs/Bugs && rm -rf "$P/Workspace/Docs/Bugs" && git -C "$P" commit -qm "no bugs folder" && git -C "$P" push -q 2>/dev/null && plan
out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -n "$(git -C "$P" ls-files acp/Workspace/Docs/Bugs/.gitignore)" ]; } || { echo "FAIL P14: the bug folder's .gitignore the install made stopped the commit, or was left out (exit $rc): $out"; exit 1; }

# P15: git's own housekeeping between the backup and apply (a gc packing every loose object) is not a change: apply
# restructures the project, every tracked file kept at its new place
conserved() { # <tree before (ls-tree -r output)>: every blob and mode outside the install's own, at its mapped place now
  git -C "$P" ls-tree -r HEAD > "$EVAL_TMP/after.tree"
  "$PY" - "$1" "$EVAL_TMP/after.tree" <<'PYEOF'
import sys
row = lambda l: (l.split("\t", 1)[1], tuple(l.split("\t", 1)[0].split()[0::2]))
before = dict(row(l) for l in open(sys.argv[1]).read().splitlines()); after = dict(row(l) for l in open(sys.argv[2]).read().splitlines())
moves = [("HANDOFF-2026-01-01.md", "acp/Workspace/Sessions/archive/HANDOFF-2026-01-01.md"), ("src/", "app/src/"), ("docs/", "app/docs/"),
         ("vendor/", "app/vendor/"), ("fixtures/", "app/fixtures/"), ("Workspace/", "acp/Workspace/")]
own = (".aicodepipeline/", ".claude/", "AGENTS.md", "CLAUDE.md", "pipeline.config.sh", ".gitignore")
bad = [p for p, v in before.items() if not (p.startswith(own) or p.endswith(("/.wo-manifest", "/.wo-meta")))
       and after.get(next((d + p[len(s):] for s, d in moves if p == s or p.startswith(s)), p)) != v]
sys.exit(1 if bad else 0)
PYEOF
}
fresh p15 && plan && git -C "$P" ls-tree -r HEAD > "$EVAL_TMP/p15.tree"
[ -n "$(find "$P/.git/objects" -type f -path '*/objects/??/*' | head -1)" ] && git -C "$P" gc -q --prune=now 2>/dev/null \
  && [ -z "$(find "$P/.git/objects" -type f -path '*/objects/??/*' | head -1)" ] || { echo "FAIL setup: p15 gc packed nothing"; exit 1; }
out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && conserved "$EVAL_TMP/p15.tree"; } || { echo "FAIL P15: a gc between the backup and apply stopped apply, or a file was not kept (exit $rc): $out"; exit 1; }
# P16: a loose object that vanishes while apply's walk reads it (packed by git meanwhile) is passed over: apply
# restructures the project, every tracked file kept. Deterministic: the objects are packed first, the loose copies kept,
# and the walk's lstat removes one loose copy as it reaches it, as gc would.
fresh p16 && plan && git -C "$P" ls-tree -r HEAD > "$EVAL_TMP/p16.tree" && git -C "$P" repack -a -q 2>/dev/null || { echo "FAIL setup: p16 repack"; exit 1; }
out="$(cd "$P" && "$PY" - "$PIPELINE_ROOT/core/hooks" <<'PYEOF' 2>&1
import os, re, sys
sys.path.insert(0, sys.argv[1]); import migrate
real, gone = os.lstat, []
def lstat(p, *a, **k):
    if not gone and re.search(r"/\.git/objects/[0-9a-f]{2}/[0-9a-f]{38}$", str(p)): os.unlink(p); gone.append(p)   # git packed it meanwhile
    return real(p, *a, **k)
os.lstat = lstat
rc = migrate.main(["apply"]); print(f"vanished={len(gone)}"); sys.exit(rc)
PYEOF
)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "vanished=1" <<< "$out" && conserved "$EVAL_TMP/p16.tree" && [ -z "$(git -C "$P" fsck --no-progress 2>&1 | grep -v '^dangling')" ]; } \
  || { echo "FAIL P16: a loose object that vanished mid-walk stopped apply, or a file was not kept (exit $rc): $out"; exit 1; }

# P17: a step costs the same at any journal length: 2,000 moves apply in under a minute (a journal rewritten whole at
# every step took minutes), every step marked done; a last journal line cut short by a stop is left out by its reader
fresh p17 && "$PY" -c 'import os, sys; [os.makedirs(f"{sys.argv[1]}/d{i:04d}") or open(f"{sys.argv[1]}/d{i:04d}/f.txt", "w").write(f"{i}\n") for i in range(2000)]' "$P" \
  && git -C "$P" add -A && git -C "$P" -c gc.auto=0 commit -qm many && git -C "$P" push -q 2>/dev/null && plan || { echo "FAIL setup: p17"; exit 1; }
t0=$SECONDS; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?; took=$((SECONDS - t0))
printf '{"kind": "mo' >> "$P/.acp-migration/journal.jsonl"
{ [ "$rc" -eq 0 ] && [ "$took" -lt 60 ] && "$PY" - "$PIPELINE_ROOT/core/hooks" "$P" <<'PYEOF'; } || { echo "FAIL P17: 2,000 moves took ${took}s (under 60 expected), or the journal is not whole (exit $rc): $out"; exit 1; }
import sys
sys.path.insert(0, sys.argv[1]); import migrate
s = migrate.read_journal(sys.argv[2])["steps"]
sys.exit(0 if sum(x["kind"] == "move" for x in s) >= 2000 and all(x["done"] for x in s) and s[-1]["kind"] == "commit" and len(s[-1]["sha"]) == 40 else 1)
PYEOF

# P9: an answer edited in moves.json to what is not an option is refused at apply (answers are outside the plan id)
fresh p9 && mkdir -p "$EVAL_TMP/p9/outside" && ln -s "$EVAL_TMP/p9/outside" "$P/.vscode" && git -C "$P" add .vscode && git -C "$P" commit -qm link && git -C "$P" push -q 2>/dev/null && plan
"$PY" -c 'import json, sys; d = json.load(open(sys.argv[1])); [q.update(answer="app") for q in d["questions"] if q.get("about") == ".vscode"]; json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)' "$P/.acp-migration/moves.json"
refused P9 "acp migrate apply: question 1 is answered 'app', which is not one of its options; answer it again"
exit 0
