#!/usr/bin/env bash
# acp migrate apply carries out what lies beside the repository, after the move commit: imports and retires orders,
# files each order's stray material, keeps the losing version of a differing file, moves private material out and logs
# into an ignored folder, records the migration in a second commit (with the project's hooks), then deletes what it
# carried, each deletion after its digest is re-taken, and the branches answered delete. It refuses in step 0 with one
# line, nothing changed; after the move commit it stops at the first surprise, saying what is committed and the way back.
# Everything here is synthetic; key-shaped lines are built at run time.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.name t && git config --global user.email t@example.com && git config --global init.defaultBranch main || { echo "FAIL setup: git identity"; exit 1; }
run() { perl -e 'alarm 600; exec @ARGV' "$@"; }
key() { printf '%s%s' AKIA "$1"; }
W=Workspace/Docs/WorkOrders; B=Workspace/Docs/Bugs

build() { # <case> [pre-commit hook, @P@ for the project]: a project with its repository in eng/ and one item of every
  # kind beside it, its hook in place, planned and backed up
  T="$EVAL_TMP/$1"; P="$T/proj"; R="$P/eng"; PF="$T/private"; mkdir -p "$T" "$PF" || return 1
  run "$PIPELINE_ROOT/bin/new-project" "$R" --name Proj >"$T/np.log" 2>&1 || { echo "FAIL setup: new-project: $(tail -1 "$T/np.log")"; exit 1; }
  ( cd "$R" && mkdir -p src docs && printf 'print(1)\n' > src/main.py && printf 'd\n' > docs/d.md && printf '# Proj\n' > README.md \
    && git add -A && git commit -qm product && run .aicodepipeline/bin/wo new "Alpha" --paths src >/dev/null 2>&1 \
    && run .aicodepipeline/bin/wo new "Beta" >/dev/null 2>&1 && run .aicodepipeline/bin/bug new "Crash" >/dev/null 2>&1 \
    && git add -A && git commit -qm orders >/dev/null 2>&1 \
    && git checkout -qb merged-old && printf 'm\n' > docs/m.md && git add -A && git commit -qm m && git checkout -q main && git merge -q --ff-only merged-old \
    && git checkout -qb side-pushed && printf 's\n' > docs/s.md && git add -A && git commit -qm s && git checkout -q main \
    && git init -q --bare "$T/remote.git" && git remote add origin "$T/remote.git" && git push -q -u origin main side-pushed 2>/dev/null ) >/dev/null 2>&1 \
    || { echo "FAIL setup: repository"; exit 1; }
  OA="$(cd "$R/$W" && ls -d WO-*-alpha)"; OB="$(cd "$R/$W" && ls -d WO-*-beta)"; BC="$(cd "$R/$B" && ls -d BUG-*-crash)"; A_="${OA%-alpha}"; B_="${OB%-beta}"; NA="${A_#WO-}"
  ( cd "$R" && printf '# design\n' > "$W/$OA/$A_-DESIGN.md" && printf '# plan\nk=%s\n' "$(key WSXEDCRFVTGBYHNU)" > "$W/$OA/$A_-PLAN.md" && printf '# handoff\n' > HANDOFF-2026-01-01.md \
    && git add -A && git commit -q --no-verify -m docs && git push -q origin main 2>/dev/null ) >/dev/null 2>&1 || { echo "FAIL setup: the alpha order's documents"; exit 1; }
  w="$P/work"; mkdir -p "$w/WO-0020-only" "$w/WO-0021-old" "$w/WO-0022-keys" "$w/WO-0000-idea" "$P/other/WO-0000-idea" "$w/old" "$w/close" "$w/diff" "$w/team/profiles" "$w/run1-logs" \
    "$P/thing-share" "$P/kb-before-1/profiles" "$P/kb-before-2/profiles" "$P/handoff" "$P/acpclone/bin" "$P/acpclone/core/hooks" || exit 1
  printf '# only\n' > "$w/WO-0020-only/WO-0020-SPEC.md"; printf 'size=small\nstatus=open\npaths=src\n' > "$w/WO-0020-only/.wo-meta"; printf 'aaaa\tsrc/main.py\n' > "$w/WO-0020-only/.wo-manifest"
  printf '# old\n' > "$w/WO-0021-old/WO-0021-SPEC.md"; printf '# V\n' > "$w/WO-0021-old/WO-0021-VERIFICATION.md"; printf '# C\n' > "$w/WO-0021-old/WO-0021-CLOSEOUT.md"; printf 'size=small\nstatus=closed\n' > "$w/WO-0021-old/.wo-meta"
  printf '# k\n' > "$w/WO-0022-keys/WO-0022-SPEC.md"; printf 'size=small\nstatus=open\n' > "$w/WO-0022-keys/.wo-meta"; printf 'k=%s\n' "$(key QAZWSXEDCRFVTGBY)" > "$w/WO-0022-keys/env.txt"
  printf '# idea\n' > "$w/WO-0000-idea/WO-0000-SPEC.md"; printf 'n\n' > "$w/WO-0000-idea/WO-0000-NOTES-1.md"; printf 'size=small\nstatus=open\n' > "$w/WO-0000-idea/.wo-meta"
  printf '# idea 2\n' > "$P/other/WO-0000-idea/WO-0000-SPEC.md"; printf 'size=small\nstatus=open\n' > "$P/other/WO-0000-idea/.wo-meta"
  cp -R "$R/$W/$OB" "$w/old/"; cp -R "$R/$B/$BC" "$w/close/"; rm -f "$w/close/$BC/.bug-meta"
  cp -R "$R/$W/$OA" "$w/diff/"; printf '# changed outside\n' >> "$w/diff/$OA/$A_-SPEC.md"; printf '# only outside\n' > "$w/diff/$OA/$A_-NOTES-9.md"
  printf '# design changed outside\n' > "$w/diff/$OA/$A_-DESIGN.md"; printf '# plan changed outside\n' > "$w/diff/$OA/$A_-PLAN.md"; mkdir -p "$w/WO-0021-old/artifacts" && printf 'B\000\001' > "$w/WO-0021-old/artifacts/run.bin"
  printf '# n\n' > "$w/$A_-notes.md"; printf 'a\n' > "$w/$A_-list.txt"; cp "$R/$W/$OA/$A_-SPEC.md" "$w/$A_-spec-copy.md"; printf '# clash\n' > "$w/$A_-SPEC.md"
  printf 'k=%s\n' "$(key PLMOKNIJBUHVYGCT)" > "$w/$B_-env.log"; printf '# p\n' > "$w/wo-0000-plan.md"; printf 'p\n' > "$w/wo-0000-dump.log"; printf 'm\n' > "$w/wo-0999-notes.md"
  printf '1\n' > "$w/$NA-misc.txt"; printf '# both\n' > "$w/$A_-vs-$B_.md"
  printf 'w\n' > "$P/acpclone/bin/wo"; printf 'i\n' > "$P/acpclone/bin/install.sh"; printf 'h\n' > "$P/acpclone/core/hooks/x.py"; printf '1.0.0\n' > "$P/acpclone/VERSION"
  ( cd "$P/acpclone" && git init -q && git add -A && git commit -qm c && git init -q --bare "$T/acpclone.git" && git remote add origin "$T/acpclone.git" && git push -q -u origin main 2>/dev/null ) || { echo "FAIL setup: second ACP"; exit 1; }
  mkdir -p "$w/tools/inner" && ( cd "$w/tools/inner" && git init -q && printf 'i\n' > i.txt && git add -A && git commit -qm i ) || { echo "FAIL setup: other repository"; exit 1; }
  printf 'mine\n' > "$P/thing-share/p.txt"; printf '# p\n' > "$w/team/profiles/a.md"; printf 'log\n' > "$w/run1-logs/a.log"; printf 'tmp\n' > "$w/scratch.txt"; printf 'k\n' > "$P/kb-notes.md"
  cp "$R/README.md" "$P/kb-before-1/profiles/readme.md"; printf '# not in history\n' > "$P/kb-before-1/profiles/new.md"
  cp "$R/README.md" "$P/kb-before-2/profiles/readme.md"; cp "$R/docs/d.md" "$P/kb-before-2/profiles/d.md"; printf '# h\n' > "$P/handoff/h.md"; printf '# audit\n' > "$P/AUDIT-2026-01-02.md"
  if [ -n "${EXTRA:-}" ]; then eval "$EXTRA" || { echo "FAIL setup: $1's extra"; exit 1; }; fi
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed "s#@P@#$P#g" > "$R/.git/hooks/pre-commit" && chmod +x "$R/.git/hooks/pre-commit" || exit 1; fi
  ( cd "$P" && run "$ACP" migrate plan >/dev/null 2>&1 && mkdir -p "$T/bk" && run "$ACP" migrate backup --to "$T/bk" >/dev/null 2>&1 ) || { echo "FAIL setup: plan or backup in $P"; exit 1; }
}
answer_all() { # every question its suggestion, the folder question the private folder, and "<about>=<answer>" overrides
  "$PY" - "$P/.acp-migration/moves.json" "${FOLDER:-$PF}" "$@" > "$T/answers" <<'PYEOF' || { echo "FAIL setup: answers"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1])); over = dict(a.split("=", 1) for a in sys.argv[3:])
for q in d["questions"]:
    a = sys.argv[2] if q["options"] == ["<a folder outside the project>"] else over.get(q.get("about"), q["suggested"])
    print(f"{q['n']}|{'folder' if q['options'] == ['<a folder outside the project>'] else '-'}|{a}")
PYEOF
  while IFS='|' read -r n f a; do
    if [ "$f" = folder ]; then ( cd "$P" && run "$ACP" migrate answer "$n" --folder "$a" >/dev/null 2>&1 ) || { echo "FAIL setup: answer $n"; exit 1; }
    else ( cd "$P" && run "$ACP" migrate answer "$n" "$a" >/dev/null 2>&1 ) || { echo "FAIL setup: answer $n ($a)"; exit 1; }; fi
  done < "$T/answers"; }
snap() { "$PY" - "$P" "$PF" <<'PYEOF'
import hashlib, os, sys
h = hashlib.sha256()
for top in sys.argv[1:]:
    for d, dirs, files in os.walk(top):
        dirs.sort(); rel = os.path.relpath(d, top)
        if rel.split(os.sep)[0] == ".acp-migration": continue
        for f in sorted(files):
            p = os.path.join(d, f); st = os.lstat(p)
            data = os.readlink(p).encode() if os.path.islink(p) else open(p, "rb").read()
            h.update(f"F {top}/{os.path.join(rel, f)} {st.st_mode} ".encode() + hashlib.sha256(data).digest())
print(h.hexdigest())
PYEOF
}
refused() { # <check> <the line's text after "acp migrate apply: "> : exit 1, that one line, nothing changed
  local s0 out rc; s0="$(snap)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && [ "$out" = "acp migrate apply: $2" ] && [ "$(snap)" = "$s0" ]; } || { echo "FAIL $1: expected exit 1 and '$2', nothing changed (exit $rc): $out"; exit 1; }; }
refused_like() { # <check> <words>: exit 1, one line holding the words, nothing changed
  local s0 out rc; s0="$(snap)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && grep -qF -- "$2" <<< "$out" && [ "$(snap)" = "$s0" ]; } || { echo "FAIL $1: expected exit 1 and one line with '$2', nothing changed (exit $rc): $out"; exit 1; }; }
setq() { "$PY" - "$P/.acp-migration/moves.json" "$1" "$2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for q in d["questions"]:
    if q.get("about") == sys.argv[2] or str(q["n"]) == sys.argv[2]: q["answer"] = sys.argv[3]
json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PYEOF
}
expect_stop() { # <check> <words of the stop line>: exit 1, the stop names the step, what is committed and the way back
  out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF -- "$2" <<< "$out" && grep -qE "committed: [0-9a-f]{12}" <<< "$out" && grep -qF "restore by hand: mkdir" <<< "$out"; } \
    || { echo "FAIL $1: expected a stop with '$2', what is committed and the way back (exit $rc): $out"; exit 1; }; }
in_git() { git -C "$R" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }

# A2 (the base failure): everything beside the repository is carried out as answered
build a2; ln -s "$PF" "$T/pflink" || { echo "FAIL setup: a link to the private folder"; exit 1; }
FOLDER="$T/pflink/" answer_all "work/WO-0021-old=retire" "eng/HANDOFF-2026-01-01.md=delete" "work/wo-0000-plan.md=adopt as $(grep -o 'adopt as WO-[0-9]*' "$P/.acp-migration/MIGRATION-PLAN.md" | sed -n '$p' | cut -c10-)"
H0="$(git -C "$R" rev-parse HEAD)"; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "^  beside the repository: .*; the record committed as [0-9a-f]\{12\} (Import work orders and the migration record)" <<< "$out"; } \
  || { echo "FAIL A2: apply did not carry out what lies beside the repository"; echo "  (exit $rc) $out" | tail -3; exit 1; }
REC="acp/Workspace/Migration/$(date +%F)"; WD="$R/acp/$W"
{ [ "$(git -C "$R" rev-list --count "$H0..HEAD")" = 2 ] && [ -z "$(git -C "$R" status --porcelain)" ] && [ "$(git -C "$R" log -1 --format=%s)" = "Import work orders and the migration record" ]; } \
  || { echo "FAIL A2: not two commits on the old head and a clean tree: $(git -C "$R" status --porcelain | head -3)"; exit 1; }
# what is left beside the repository: only the other repository, answered "keep beside the project"
{ [ "$(cd "$P" && ls -A | LC_ALL=C sort | tr '\n' ' ')" = ".acp-migration eng work " ] && [ "$(cd "$P/work" && find . -mindepth 1 -maxdepth 2 | LC_ALL=C sort | tr '\n' ' ')" = "./tools ./tools/inner " ]; } || { echo "FAIL A2: something beside the repository was left: $(cd "$P" && find . -mindepth 1 -maxdepth 2 -not -path './.acp-migration*' -not -path './eng*' | head -8 | tr '\n' ' ')"; exit 1; }
# A14: an imported open order: its manifest and declared paths are mapped, the old manifest kept in the record
{ grep -q "	app/src/main.py$" "$WD/WO-0020-only/.wo-manifest" && grep -qx "paths=app/src" "$WD/WO-0020-only/.wo-meta" && grep -qx "paths_pre_migration=src" "$WD/WO-0020-only/.wo-meta" \
  && grep -q "	src/main.py$" "$R/$REC/pre-migration/acp/$W/copy-of-WO-0020-only/.wo-manifest" && [ ! -e "$WD/WO-0020-only/.wo-manifest.pre-migration" ] && in_git "acp/$W/WO-0020-only/.wo-manifest"; } \
  || { echo "FAIL A14: an imported open order's paths were not mapped, or the old manifest is not in the record"; exit 1; }
# A11: a retired order is kept whole in the record, committed, listed, and is no order
{ cmp -s "$R/$REC/retired/work/copy-of-WO-0021-old/WO-0021-CLOSEOUT.md" <(printf '# C\n') && in_git "$REC/retired/work/copy-of-WO-0021-old/WO-0021-SPEC.md" \
  && grep -q "^$REC/retired/work/copy-of-WO-0021-old	retired	WO-0021-VERIFICATION.md	" "$R/$REC/ORDERS.tsv" && ! ls -d "$WD"/WO-0021-* >/dev/null 2>&1; } \
  || { echo "FAIL A11: a retired order is not kept whole in the record, committed and listed as retired"; exit 1; }
# placeholders: both folders adopted under their own numbers, their files renamed; the note adopted through wo adopt (A15)
PA="$(ls -d "$WD"/WO-*-idea | sed -n 1p)"; PB="$(ls -d "$WD"/WO-*-idea | sed -n 2p)"; NP="$(basename "$PB")"; NP="${NP%-idea}"
{ [ -n "$PB" ] && [ -f "$PB/$NP-SPEC.md" ] && [ -f "$PB/$NP-NOTES-1.md" ] && ! ls "$PA" "$PB" | grep -q "WO-0000" \
  && ls "$WD" | grep -q "^WO-[0-9]*-p$" && grep -qx "status=migrated" "$WD"/WO-*-p/.wo-meta; } \
  || { echo "FAIL A15: the placeholders were not adopted under new numbers with their files renamed, or the note not adopted: $(ls "$WD" | tr '\n' ' ')"; exit 1; }
# A10: the order in two places that differ: the only-outside note carried in, the repository's version kept, the other in kept/
OA="$(cd "$WD" && ls -d WO-*-alpha)"; A_="${OA%-alpha}"
{ [ -f "$WD/$OA/$A_-NOTES-9.md" ] && ! grep -q "changed outside" "$WD/$OA/$A_-SPEC.md" && grep -q "changed outside" "$R/$REC/kept/work/diff/copy-of-$OA/$A_-SPEC.md" && in_git "$REC/kept/work/diff/copy-of-$OA/$A_-SPEC.md"; } \
  || { echo "FAIL A10: the differing copy was not merged as answered (repository), with the other version kept"; exit 1; }
# A17: 278's kinds: a note filed and committed; an artifact filed under artifacts/, ignored; the duplicate dropped
{ in_git "acp/$W/$OA/$A_-NOTES-1.md" && [ -f "$WD/$OA/artifacts/work/$A_-list.txt" ] && ! in_git "acp/$W/$OA/artifacts/work/$A_-list.txt" \
  && [ ! -e "$WD/$OA/artifacts/.gitignore" ]; } || { echo "FAIL A17: an order's note or artifact was not filed as planned (the artifact ignored through the orders folder)"; exit 1; }
# A12: what is kept with the logs is in the logs folder, and git ignores it (not only *.log)
{ [ -f "$R/acp/Workspace/Testing/logs/work/scratch.txt" ] && [ "$(od -An -c "$R/acp/Workspace/Testing/logs/.gitignore" | tr -d ' ')" = '*\n' ] \
  && ! in_git "acp/Workspace/Testing/logs/work/scratch.txt"; } || { echo "FAIL A12: a file kept with the logs is not in an ignored logs folder"; exit 1; }
# A16 (D5): a snapshot with a file in no commit is asked (logs suggested); one wholly in history is dropped
{ [ -f "$R/acp/Workspace/Testing/logs/kb-before-1/profiles/new.md" ] && [ ! -e "$P/kb-before-2" ]; } || { echo "FAIL A16: the snapshots were not handled by what the history holds"; exit 1; }
# private material, the second ACP copy, the branches
{ [ -f "$PF/work/WO-0022-keys/env.txt" ] && [ -f "$PF/work/team/profiles/a.md" ] && [ -f "$PF/thing-share/p.txt" ] && [ ! -e "$P/acpclone" ] \
  && ! git -C "$R" rev-parse -q --verify refs/heads/merged-old >/dev/null && git -C "$R" rev-parse -q --verify refs/heads/side-pushed >/dev/null; } \
  || { echo "FAIL A2: private material, the second ACP copy or the branches were not handled as answered"; exit 1; }
# A8: the record: every file, no path of this machine in it, applied.json done with both commits
for f in MIGRATION-PLAN.md moves.json backup.json journal.json ORDERS.tsv README.md; do in_git "$REC/$f" || { echo "FAIL A8: the record lacks $f"; exit 1; }; done
! grep -rqF -e "$P" -e "$PF" -e "$T" "$R/$REC" || { echo "FAIL A8: the committed record names a path of this machine"; exit 1; }
"$PY" -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if r["outcome"] == "done" and r["commit"] and r["commit_outside"] else 1)' "$P/.acp-migration/applied.json" || { echo "FAIL A8: applied.json does not record both commits"; exit 1; }
# S706i-4: the private folder was answered through a link, with a trailing slash; no form of a path of this machine is in the record
! grep -rqF -e "$T" -e "${T#/private}" -e "/private$T" -e pflink "$R/$REC" || { echo "FAIL S706i-4: the committed record names a path of this machine in another form"; exit 1; }
# the items moved to the private folder are numbered in the record, never named
{ grep -q "<private item 1>" "$R/$REC/README.md" && ! grep -rqF -e WO-0022-keys -e thing-share -e "work/team" "$R/$REC"; } || { echo "FAIL A8: the record names an item moved to the private folder"; exit 1; }
# S706i-3: the retired order's artifacts/ is not committed: it is in the private folder, and the record names it
{ [ ! -e "$R/$REC/retired/work/copy-of-WO-0021-old/artifacts" ] && [ -f "$PF/work/WO-0021-old/artifacts/run.bin" ] && grep -q "work/WO-0021-old/artifacts" "$R/$REC/README.md"; } \
  || { echo "FAIL S706i-3: a retired order's artifacts/ was committed, or not kept in the private folder"; exit 1; }
# B6: a root loose document answered delete goes in the second commit
{ [ ! -e "$R/HANDOFF-2026-01-01.md" ] && git -C "$R" show --name-status --format= HEAD | grep -qx "D	HANDOFF-2026-01-01.md"; } || { echo "FAIL B6: a root document answered delete is not deleted in the second commit"; exit 1; }
# S706i-6: the migrated project is in order by the structure rule
out="$(cd "$R" && python3 acp/.aicodepipeline/core/hooks/layout.py --root "$R" 2>&1)" || { echo "FAIL S706i-6: the structure rule finds the migrated project out of order: $out"; exit 1; }

# A3: step 0 refuses with one line, and nothing changes, the move commit included
EXTRA='git -C "$R" branch wtb && git -C "$R" worktree add -q "$T/wt" wtb && mkdir -p "$P/work/linkout" && ln -s /etc "$P/work/linkout/l"' build a3; answer_all
setq "work/diff/$(cd "$R/$W" && ls -d WO-*-alpha)" "file by file"
Q="$("$PY" -c 'import json,sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q.get("about","").startswith("work/diff/")][0])' "$P/.acp-migration/moves.json")"
refused A3 "question $Q: apply does not merge \`work/diff/$(cd "$R/$W" && ls -d WO-*-alpha)\` file by file; merge it by hand, commit, and plan again"
setq "work/diff/$(cd "$R/$W" && ls -d WO-*-alpha)" repository
# A13: what would be committed is read for secrets first
setq "work/WO-0022-keys" import
refused A13 "\`work/WO-0022-keys\` may hold something private (WO-0022-keys/env.txt), and the answer would commit it; answer private folder where offered, or move it out by hand and plan again"
setq "work/WO-0022-keys" "private folder"
# A15: only a note can be adopted as an order
setq "work/wo-0000-dump.log" "$("$PY" -c 'import json,sys; print([o for q in json.load(open(sys.argv[1]))["questions"] if q.get("about") == "work/wo-0000-dump.log" for o in q["options"] if o.startswith("adopt as")][0])' "$P/.acp-migration/moves.json")"
Q="$("$PY" -c 'import json,sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q.get("about") == "work/wo-0000-dump.log"][0])' "$P/.acp-migration/moves.json")"
refused A15 "question $Q: only a note (.md) can be adopted as an order; answer logs, private folder or delete"
setq "work/wo-0000-dump.log" logs
# S706i-5: a source holding a link that points outside it cannot be carried as it is
refused S706i-5 "\`work/linkout\` cannot be carried as it is: l is a link to /etc, outside it; move it by hand, or answer delete, and plan again"
RQ="$("$PY" -c 'import json,sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q["options"] == ["keep", "delete"]][0])' "$P/.acp-migration/moves.json")"; setq "$RQ" delete
# B5: a branch a worktree has checked out is suggested keep, and refused when answered delete
"$PY" -c 'import json,sys; sys.exit(0 if [q["suggested"] for q in json.load(open(sys.argv[1]))["questions"] if q.get("about") == "branch wtb"] == ["keep"] else 1)' "$P/.acp-migration/moves.json" \
  || { echo "FAIL B5: a branch a worktree has checked out is not suggested keep"; exit 1; }
setq "branch wtb" delete; Q="$("$PY" -c 'import json,sys; print([q["n"] for q in json.load(open(sys.argv[1]))["questions"] if q.get("about") == "branch wtb"][0])' "$P/.acp-migration/moves.json")"
refused B5 "question $Q: branch \`wtb\` is checked out in a worktree, and git deletes no such branch; answer keep, or remove the worktree and plan again"
setq "branch wtb" keep
# S706i-5: a destination already taken, or one below a link, is refused before anything moves
mkdir -p "$PF/thing-share"; refused_like S706i-5 "/thing-share is already there, or lies below a link; apply never moves anything over it"; rmdir "$PF/thing-share"
mkdir -p "$T/elsewhere" && ln -s "$T/elsewhere" "$PF/work" && refused_like S706i-5 "lies below a link; apply never moves anything over it"; rm "$PF/work"
# A3c: a branch answered delete that moved after the plan (a fresh backup taken, so the backup check passes)
TIP="$(git -C "$R" rev-parse merged-old)"; git -C "$R" update-ref refs/heads/merged-old "$(git -C "$R" rev-list --max-parents=0 HEAD)" \
  && ( cd "$P" && mkdir -p "$T/bk1" && run "$ACP" migrate backup --to "$T/bk1" >/dev/null 2>&1 ) || { echo "FAIL setup: a moved branch"; exit 1; }
refused A3 "branch \`merged-old\` is not at the commit the owner answered about (${TIP:0:12}); plan again"
git -C "$R" update-ref refs/heads/merged-old "$TIP" || { echo "FAIL setup: the branch put back"; exit 1; }
# A3b: an item changed after the plan, though the backup was taken after the change (so the backup check passes)
printf 'more\n' >> "$P/work/scratch.txt"
( cd "$P" && mkdir -p "$T/bk2" && run "$ACP" migrate backup --to "$T/bk2" >/dev/null 2>&1 ) || { echo "FAIL setup: a second backup"; exit 1; }
refused A3 "\`work/scratch.txt\` has changed since the plan; apply acts only on what the owner answered about: plan again"
# A9: a plan made before this order (no digests) is refused with the re-plan line
"$PY" - "$P/.acp-migration" <<'PYEOF' || { echo "FAIL setup: an older plan"; exit 1; }
import hashlib, json, os, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "moves.json")))
for e in m["entries"]: e.pop("digest", None)
old = m["plan_id"]; m.pop("plan_id"); m.pop("plan_md_sha256")
x = dict(m); x["questions"] = [dict(q, answer=None) for q in m["questions"]]
pid = hashlib.sha256(json.dumps(x, sort_keys=True).encode("utf-8", "surrogateescape")).hexdigest()
md = open(os.path.join(d, "MIGRATION-PLAN.md"), encoding="utf-8").read().replace(old, pid)
open(os.path.join(d, "MIGRATION-PLAN.md"), "w", encoding="utf-8").write(md)
m["plan_id"], m["plan_md_sha256"] = pid, hashlib.sha256(md.encode("utf-8")).hexdigest()
json.dump(m, open(os.path.join(d, "moves.json"), "w"), indent=1, sort_keys=True)
PYEOF
refused A9 "the plan was made before apply could check what it moves and deletes; run acp migrate plan --replace (its answers are lost; answer them again)"

# A4: an item changed after the second commit (by the project's own pre-commit hook) stops at its deletion; nothing more is deleted
build a4 '#!/bin/sh
printf "late\n" >> "@P@/work/scratch.txt"'; answer_all "work/diff/$(cd "$R/$W" && ls -d WO-*-alpha)=outside"
expect_stop A4 "apply stopped at the deletions beside the repository (\`work/scratch.txt\` changed before its deletion; it was not deleted)"
{ [ -f "$P/work/scratch.txt" ] && [ "$(git -C "$R" log -1 --format=%s)" = "Import work orders and the migration record" ] \
  && "$PY" -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["outcome"] == "stopped at the deletions" else 1)' "$P/.acp-migration/applied.json"; } \
  || { echo "FAIL A4: the stop did not leave the changed item, the second commit, and applied.json stopped at the deletions"; exit 1; }
# A10 (outside): the outside version landed in the order folder, the repository's in kept/
OA="$(cd "$R/acp/$W" && ls -d WO-*-alpha)"; A_="${OA%-alpha}"
{ grep -q "changed outside" "$R/acp/$W/$OA/$A_-SPEC.md" && [ -f "$R/acp/Workspace/Migration/$(date +%F)/kept/eng/acp/$W/copy-of-$OA/$A_-SPEC.md" ] \
  && ! grep -q "changed outside" "$R/acp/Workspace/Migration/$(date +%F)/kept/eng/acp/$W/copy-of-$OA/$A_-SPEC.md"; } \
  || { echo "FAIL A10: answered outside, the outside version did not land with the repository's kept"; exit 1; }
# S706i-2: the repository's losing version holding a key line went to the private folder, never into kept/
{ [ -f "$PF/eng/$W/$OA/$A_-PLAN.md" ] && [ ! -e "$R/acp/Workspace/Migration/$(date +%F)/kept/eng/acp/$W/copy-of-$OA/$A_-PLAN.md" ] \
  && [ -f "$R/acp/Workspace/Migration/$(date +%F)/kept/eng/acp/$W/copy-of-$OA/$A_-DESIGN.md" ]; } \
  || { echo "FAIL S706i-2: a losing version holding a key line was kept in the record, or not moved to the private folder"; exit 1; }

# D4: the second commit runs the project's hooks; a refusal stops there, nothing beside the repository deleted
build d4 '#!/bin/sh
echo "hook says no" >&2; exit 1'; answer_all
expect_stop D4 "apply stopped at the migration record and the second commit beside the repository (the second commit failed (hook says no); what was carried in is staged)"
{ [ -d "$P/kb-before-2" ] && [ -f "$P/work/scratch.txt" ] && [ "$(git -C "$R" log -1 --format=%s)" = "Move the product into app/ and the pipeline into acp/" ]; } \
  || { echo "FAIL D4: a refused second commit still deleted something beside the repository, or committed"; exit 1; }

# A7: a branch moved after the plan (here by the hook) is not deleted, and apply stops there
build a7 '#!/bin/sh
git update-ref refs/heads/merged-old $(git rev-list --max-parents=0 HEAD)'; answer_all   # the root commit: never its tip
expect_stop A7 "apply stopped at the branches beside the repository (branch \`merged-old\` moved during apply; it was not deleted)"
git -C "$R" rev-parse -q --verify refs/heads/merged-old >/dev/null || { echo "FAIL A7: a branch that moved was deleted"; exit 1; }
# S706i-5: failures planted inside apply (ACP_TEST_FAIL), each stopping with what is committed and the way back, and
# leaving every tracked file as the move commit left it, and nothing of the step in hand (the steps done before it stay)
planted() { # <case> <ACP_TEST_FAIL> <check> <words of the stop line> [answers ...]
  local p_case="$1" p_fail="$2" p_check="$3" p_words="$4"; shift 4   # names build and answer_all do not use
  build "$p_case"; answer_all "$@"; export ACP_TEST_FAIL="$p_fail"; expect_stop "$p_check" "$p_words"; unset ACP_TEST_FAIL
  { git -C "$R" diff --quiet HEAD && [ -z "$(find "$R" -name '*.acp-migrate-*' | head -1)" ] && [ "$(git -C "$R" log -1 --format=%s)" = "Move the product into app/ and the pipeline into acp/" ] \
    && "$PY" -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["outcome"].startswith("stopped at ") else 1)' "$P/.acp-migration/applied.json"; } \
    || { echo "FAIL $p_check: after the stop a tracked file changed, a temporary copy is left, or applied.json does not say stopped: $(git -C "$R" status --porcelain | head -3)"; exit 1; }; }
planted f1 copy:3 S706i-5 "apply stopped at the copies into the repository beside the repository (OSError: [Errno 5] a failure planted at copy 3)"
planted f2 signal:4 S706i-5 "apply stopped at the copies into the repository beside the repository (KeyboardInterrupt"
DIFF="work/diff/$(cd "$EVAL_TMP/a2/proj/eng/acp/$W" && ls -d WO-*-alpha)"
# S706i-1: a merge answered outside that fails after a winner is in place puts the repository's versions back first
planted f3 replace:2 S706i-1 "apply stopped at the copies into the repository beside the repository (OSError: [Errno 5] a failure planted at replace 2)" "$DIFF=outside"
OA="$(cd "$R/acp/$W" && ls -d WO-*-alpha)"; A_="${OA%-alpha}"
{ ! grep -q "changed outside" "$R/acp/$W/$OA/$A_-SPEC.md" "$R/acp/$W/$OA/$A_-DESIGN.md" "$R/acp/$W/$OA/$A_-PLAN.md" && [ ! -e "$R/acp/Workspace/Migration/$(date +%F)/kept" ]; } \
  || { echo "FAIL S706i-1: after a failed merge the repository's versions are not back, or a saved copy was left"; exit 1; }
planted f4 keep:2 S706i-1 "apply stopped at the copies into the repository beside the repository (OSError: [Errno 5] a failure planted at keep 2)" "$DIFF=outside"
# S706i2-1: a merge whose put-back fails too keeps the saved copy it names, and every folder holding it: the repository's
# version is on disk at the place the stop line names, and no temporary copy is left
build f7; answer_all "$DIFF=outside"; export ACP_TEST_FAIL="replace:2,putback:1"
expect_stop S706i2-1 "the merge stopped and could not put back acp/$W/"; unset ACP_TEST_FAIL
OA="$(cd "$R/acp/$W" && ls -d WO-*-alpha)"; A_="${OA%-alpha}"; SAVED="$(sed -n 's/.*(its version is at \([^)]*\)).*/\1/p' <<< "$out")"
{ [ -n "$SAVED" ] && [ "$(cat "$SAVED" 2>/dev/null)" = "# design" ] && [ -z "$(find "$R" "$PF" -name '*.acp-migrate-*' | head -1)" ] \
  && grep -q "^# plan$" "$R/acp/$W/$OA/$A_-PLAN.md" && ! grep -q "changed outside" "$R/acp/$W/$OA/$A_-SPEC.md"; } \
  || { echo "FAIL S706i2-1: the saved copy the stop line names is not on disk with the repository's version, or a temporary copy is left (saved: ${SAVED:-none})"; exit 1; }
# a malformed ACP_TEST_FAIL is warned about and ignored
warn="$(ACP_TEST_FAIL=nonsense "$PY" -c 'import importlib.machinery as m, importlib.util as u, sys; l = m.SourceFileLoader("mg", sys.argv[1]); mod = u.module_from_spec(u.spec_from_loader("mg", l)); l.exec_module(mod); print(mod.fail_point("copy"))' "$PIPELINE_ROOT/core/hooks/migrate.py" 2>&1)"
{ grep -qx False <<< "$warn" && grep -q "ACP_TEST_FAIL='nonsense' is not <point>:<n>" <<< "$warn"; } || { echo "FAIL S706i2-1: a malformed ACP_TEST_FAIL was not ignored with a warning: $warn"; exit 1; }
# a destination taken during apply (here just before the second copy) is never copied over
build f5; answer_all; export ACP_TEST_FAIL=occupy:2; expect_stop S706i-5 "appeared after the checks, or lies below a link; apply never copies over anything"; unset ACP_TEST_FAIL
git -C "$R" diff --quiet HEAD || { echo "FAIL S706i-5: a destination taken during apply was copied over"; exit 1; }
# S706i-4: a path of this machine left in the record (planted after the scrub) refuses the second commit, naming the file
build f6; answer_all "work/WO-0021-old=retire"; export ACP_TEST_FAIL=leak:1
expect_stop S706i-4 "apply stopped at the migration record and the second commit beside the repository (the record would commit a path of this machine (README.md); nothing was committed)"; unset ACP_TEST_FAIL
echo "migrate-apply-beside: all checks passed"
