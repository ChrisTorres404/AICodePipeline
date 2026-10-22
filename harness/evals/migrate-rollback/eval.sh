#!/usr/bin/env bash
# acp migrate rollback puts a migrated project back exactly as its backup holds it (every entry, .git and times
# included), keeps the migrated project whole beside it and removes nothing; it refuses, touching nothing, whatever it
# cannot account for; and a rollback stopped part-way is read by device and inode by every acp migrate command.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"; MIG="$PIPELINE_ROOT/core/hooks/migrate.py"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.name t && git config --global user.email t@example.com && git config --global init.defaultBranch main || { echo "FAIL setup: git identity"; exit 1; }
run() { perl -e 'alarm 300; exec @ARGV' "$@"; }
umask 077   # the restore must not depend on the umask
BASE="$EVAL_TMP/base"
run "$PIPELINE_ROOT/bin/new-project" "$BASE/proj" --name Proj >"$EVAL_TMP/np.log" 2>&1 || { echo "FAIL setup: new-project: $(tail -1 "$EVAL_TMP/np.log")"; exit 1; }
( cd "$BASE/proj" && mkdir -p src && printf 'print(1)\n' > src/main.py && printf '# Proj\n' > README.md \
  && ln -s main.py src/rel-link && ln -s /etc/hosts src/abs-link && ln -s /nonexistent/x src/dangling \
  && printf 's\n' > src/secret.txt && chmod 0640 src/secret.txt && printf 'h\n' > src/hard1 && ln src/hard1 src/hard2 \
  && git add -A && git commit -qm product && run "$PIPELINE_ROOT/bin/wo" new "Paths order" --paths src >/dev/null 2>&1 && git add -A && git commit -qm order \
  && git init -q --bare "$BASE/remote.git" && git remote add origin "$BASE/remote.git" && git push -q -u origin main 2>/dev/null ) || { echo "FAIL setup: product"; exit 1; }
fresh() { # <case>: a copy of the base project at $P with its own remote
  P="$EVAL_TMP/$1/proj"; rm -rf "$EVAL_TMP/$1"; mkdir -p "$EVAL_TMP/$1" && cp -Rp "$BASE/proj" "$P" && cp -R "$BASE/remote.git" "$EVAL_TMP/$1/remote.git" \
    && git -C "$P" remote set-url origin "$EVAL_TMP/$1/remote.git" && P="$(cd "$P" && pwd -P)" \
    && ln -f "$P/src/hard1" "$P/src/hard2" || { echo "FAIL setup: copy $1"; exit 1; }; }   # a copy does not keep the hard link: made again
prepare() { # plan, back up, answer every question with its suggestion
  ( cd "$P" && run "$ACP" migrate plan >/dev/null 2>&1 && mkdir -p "$P.bk" && run "$ACP" migrate backup --to "$P.bk" >/dev/null 2>&1 ) || { echo "FAIL setup: plan or backup in $P"; exit 1; }
  "$PY" -c 'import json, sys; [print(q["n"], q["suggested"]) for q in json.load(open(sys.argv[1]))["questions"]]' "$P/.acp-migration/moves.json" | while read -r n v; do
    ( cd "$P" && run "$ACP" migrate answer "$n" "$v" >/dev/null 2>&1 ) || { echo "FAIL setup: answer $n"; exit 1; }; done; }
applied() { prepare; out="$(cd "$P" && run "$ACP" migrate apply 2>&1)" || { echo "FAIL setup: apply in $P: $out"; exit 1; }; }
same() { # <tree> <manifest file>: manifest_of(tree) equals the manifest's entries exactly, every field
  "$PY" - "$MIG" "$1" "$2" <<'PYEOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
want, got = json.load(open(sys.argv[3]))["entries"], m.manifest_of(sys.argv[2])
if got != want: print("  differs:", m.changed(want, got)); sys.exit(1)
PYEOF
}
listing() { "$PY" - "$EVAL_TMP/$1" <<'PYEOF'
import hashlib, os, sys
top, h = sys.argv[1], hashlib.sha256()
for d, dirs, files in os.walk(top):
    dirs.sort()
    for n in sorted(dirs + files):
        p = os.path.join(d, n); st = os.lstat(p); h.update(f"{os.path.relpath(p, top)} {st.st_mode} {st.st_size} {st.st_mtime_ns}\n".encode())
        if os.path.isfile(p) and not os.path.islink(p): h.update(hashlib.sha256(open(p, "rb").read()).digest())
print(h.hexdigest())
PYEOF
}
refused() { # <case> <id> <expected part> [rollback args...]: rollback refuses with it, and nothing beside or in the project changes
  local c="$1" id="$2" want="$3" s0 out rc; shift 3; s0="$(listing "$c")"; out="$(cd "$P" && run "$ACP" migrate rollback "$@" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF -- "$want" <<< "$out" && [ "$(listing "$c")" = "$s0" ]; } || { echo "FAIL $id: expected a refusal with '$want', nothing changed (exit $rc): $out"; exit 1; }; }

mvs_free() { "$PY" -c 'import os,re,shlex,sys   # each printed sequence, replayed in order: no mv lands on a name taken at that point
for seq in re.findall(r"to (?:finish|undo): ([^|;]*)", sys.argv[1]):
    names = {}
    exists = lambda p: names[p] if p in names else os.path.lexists(p)
    for a, b in re.findall(r"mv (\x27[^\x27]*\x27|\S+) (\x27[^\x27]*\x27|\S+)", seq):
        a, b = shlex.split(a)[0], shlex.split(b)[0]
        if exists(b) or not exists(a): sys.exit(1)
        names[a], names[b] = False, True' "$1"; }
# K1, K2, K11, K13: a real apply, then rollback: the project is the backup exactly, HEAD is the pre-apply one, git fsck is
# clean, links, modes and the hard link come back under umask 077; the migrated project is kept whole beside it
fresh k1 && NO="$(ls "$P/Workspace/Docs/WorkOrders" | sed -n 's/^WO-\([0-9]*\)-paths-order$/\1/p')" && (cd "$P" && run .aicodepipeline/bin/wo start "$NO" >/dev/null 2>&1) \
  && git -C "$P" add -A && git -C "$P" commit -qm started && git -C "$P" push -q 2>/dev/null || { echo "FAIL setup: wo start"; exit 1; }
applied && H0="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["head_before"])' "$P/.acp-migration/applied.json")"
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; rc=$?
K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && grep -q "^acp migrate rollback: $P is back as the backup of [0-9T:-]* holds it" <<< "$out" && [ -n "$K" ] && [ -f "$K/.acp-migration/rollback.json" ] \
  && [ ! -e "$P.rollback-state.json" ] && [ -z "$(ls -d "$P".restored-* 2>/dev/null)" ]; } || { echo "FAIL K1: rollback did not put the project back (exit $rc): $out"; exit 1; }
same "$P" "$K/.acp-migration/manifest.json" || { echo "FAIL K1: the restored project is not exactly as the backup holds it"; exit 1; }
{ [ "$(git -C "$P" rev-parse HEAD)" = "$H0" ] && git -C "$P" fsck --no-progress >/dev/null 2>&1 && [ "$(readlink "$P/src/rel-link")" = main.py ] \
  && [ "$("$PY" -c 'import os,sys; a,b=os.stat(sys.argv[1]),os.stat(sys.argv[2]); print(a.st_ino==b.st_ino)' "$P/src/hard1" "$P/src/hard2")" = True ]; } \
  || { echo "FAIL K1: HEAD, git fsck, a link or the hard link is not as before apply"; exit 1; }
same "$K" "$K/.acp-migration/applied-manifest.json" || { echo "FAIL K2: the kept project is not the migrated project apply left"; exit 1; }
ko="$(cd "$K" && run "$ACP" migrate plan 2>&1)"; grep -qF "this folder is the migrated project a rollback kept on" <<< "$ko" || { echo "FAIL K2: a command run in the kept folder did not say what it is: $ko"; exit 1; }
grep -qF "Worktrees in $K that point at the restored project; do not run git in them: $K/" <<< "$out" || { echo "FAIL K13: the order worktree in the kept folder was not named: $out"; exit 1; }
# K3: never migrated; restored by an earlier rollback; an interrupted apply (outcome started), refused unless asked
refused k1 K3 "this project is the one a rollback restored on"
fresh k3 && prepare && refused k3 K3 "this project was never migrated by acp migrate apply; there is nothing to roll back"
"$PY" - "$P" <<'PYEOF'
import json, os, sys
p = sys.argv[1]; b = json.load(open(os.path.join(p, ".acp-migration", "backup.json")))
json.dump({"format": 1, "plan_id": "x", "head_before": "x", "outcome": "started", "backup_archive": b["archive"],
           "backup_archive_sha256": b["archive_sha256"], "backup_manifest_sha256": b["manifest_sha256"]}, open(os.path.join(p, ".acp-migration", "applied.json"), "w"))
PYEOF
refused k3 K3 "an apply was interrupted here, so there is no record of what changed after it began. Restore by hand: mkdir"
out="$(cd "$P" && run "$ACP" migrate rollback --after-interrupted-apply 2>&1)"; rc=$?; K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && same "$P" "$K/.acp-migration/manifest.json"; } || { echo "FAIL K3: --after-interrupted-apply did not restore the backup (exit $rc): $out"; exit 1; }
fresh k3b && applied && refused k3b K3 "there is no interrupted apply here" --after-interrupted-apply
# K4: a copy of the project (another inode); another archive than apply recorded; a corrupted archive; an edited
# manifest; a .sha256 that does not match: each refuses
cp -Rp "$P" "$EVAL_TMP/k3b/copy"; P2="$P"; P="$EVAL_TMP/k3b/copy"; refused k3b K4 "backup.json does not describe this project"; P="$P2"
A="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["backup_archive"])' "$P/.acp-migration/applied.json")"
cp "$P/.acp-migration/applied.json" "$EVAL_TMP/ap.json"; "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); r["backup_archive_sha256"]="0"*64; json.dump(r, open(sys.argv[1],"w"))' "$P/.acp-migration/applied.json"
refused k3b K4 "the backup recorded now is not the one apply used"; cp "$EVAL_TMP/ap.json" "$P/.acp-migration/applied.json"
cp "$A" "$EVAL_TMP/a.tar"; printf x >> "$A"; refused k3b K4 "is not the one apply used: its sha256 differs"; cp "$EVAL_TMP/a.tar" "$A"
cp "$P/.acp-migration/manifest.json" "$EVAL_TMP/m.json"; perl -pi -e 's/"mtime_ns": 1/"mtime_ns": 2/' "$P/.acp-migration/manifest.json"
refused k3b K4 "manifest.json is not the one the backup recorded"; cp "$EVAL_TMP/m.json" "$P/.acp-migration/manifest.json"
cp "$A.sha256" "$EVAL_TMP/s"; printf 'x\n' > "$A.sha256"; refused k3b K4 ".sha256 does not match"; cp "$EVAL_TMP/s" "$A.sha256"
# K17: --archive names a moved archive's copy, only when its sha256 matches
mv "$A" "$EVAL_TMP/moved.tar"; refused k3b K17 "name a copy with --archive"; printf x > "$EVAL_TMP/wrong.tar"
refused k3b K17 "is not the archive apply used" --archive "$EVAL_TMP/wrong.tar"
out="$(cd "$P" && run "$ACP" migrate rollback --archive "$EVAL_TMP/moved.tar" 2>&1)" || { echo "FAIL K17: --archive with the right copy did not restore: $out"; exit 1; }
# K5, K12: a change outside .git refuses, with or without the flag; an index refresh (git status) is allowed; a commit
# refuses with the repository line, and goes ahead with --accept-repository-changes, listing it; .gitignore is not .git
fresh k5 && applied && printf 'print(2)\n' > "$P/app/src/main.py" && refused k5 K5 "the project changed after apply: app/src/main.py"
o5="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; grep -qF "acp migrate rollback --keep-changes; or restore by hand: mkdir" <<< "$o5" || { echo "FAIL K5: the refusal did not give both ways out: $o5"; exit 1; }
refused k5 K12 "the project changed after apply" --accept-repository-changes
out="$(cd "$P" && run "$ACP" migrate rollback --keep-changes 2>&1)"; rc=$?; K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && grep -qF "Changes after apply, kept, stay in $K: app/src/main.py" <<< "$out" && [ "$(cat "$K/app/src/main.py")" = "print(2)" ] \
  && [ "$(cat "$P/src/main.py")" = "print(1)" ]; } || { echo "FAIL K5: --keep-changes did not roll back and keep the edit in the kept folder (exit $rc): $out"; exit 1; }
# a file added after apply and removed again leaves only a folder's time changed: that is no change
fresh k5b && applied && printf 'x\n' > "$P/app/src/later.txt" && rm "$P/app/src/later.txt"
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)" || { echo "FAIL K5: a file added and removed after apply still refused the rollback: $out"; exit 1; }
fresh k12r && applied && git -C "$P" update-index --assume-unchanged README.md   # the index rewritten, what it stages unchanged
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)" || { echo "FAIL K12: an index rewritten with the same staged content refused the rollback: $out"; exit 1; }
# git's own housekeeping after apply (a gc packs and prunes objects, packs refs) is no change: the recorded git state is
# the same; and a record from before the git state (no "git") still allows an index rewritten with the same content
fresh k12g && applied && git -C "$P" gc -q --prune=now && out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)" || { echo "FAIL K12: a gc after apply refused the rollback: $out"; exit 1; }
fresh k12o && applied && "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); r.pop("git", None); json.dump(r, open(sys.argv[1],"w"))' "$P/.acp-migration/applied.json" \
  && git -C "$P" update-index --assume-unchanged README.md && out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)" || { echo "FAIL K12: with an older record, an index rewritten with the same content refused: $out"; exit 1; }
fresh k12 && applied && git -C "$P" status >/dev/null && git -C "$P" commit -q --allow-empty -m later
refused k12 K12 "the repository changed after apply (for example a fetch, a commit, or git's own housekeeping such as gc: .git: refs refs/heads/main moved"
cp -p "$P/.gitignore" "$EVAL_TMP/gi"; printf 'x\n' >> "$P/.gitignore"; refused k12 K12 "the project changed after apply: .gitignore" --accept-repository-changes; cp -p "$EVAL_TMP/gi" "$P/.gitignore"
out="$(cd "$P" && run "$ACP" migrate rollback --accept-repository-changes 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "Repository changes after apply, accepted, stay in" <<< "$out"; } || { echo "FAIL K12: --accept-repository-changes did not go ahead and list them (exit $rc): $out"; exit 1; }
# K6: a restore that fails (a file size limit) leaves P untouched and the restored copy for the person to remove
fresh k6 && applied && s0="$(listing k6)"; out="$(cd "$P" && ulimit -f 0 && run "$ACP" migrate rollback 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "the restore stopped before anything was swapped" <<< "$out" && grep -qF "remove it yourself" <<< "$out" \
  && [ -n "$(ls -d "$P".restored-* 2>/dev/null)" ] && [ ! -e "$P.rollback-state.json" ] && [ -z "$(ls -d "$P".pre-rollback-* 2>/dev/null)" ]; } \
  || { echo "FAIL K6: a failed restore did not leave P untouched and name the copy (exit $rc): $out"; exit 1; }
R6="$(ls -d "$P".restored-* | head -1)"; sleep 1; out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "A restored copy an earlier, interrupted rollback left, not used; remove it yourself: $R6" <<< "$out"; } \
  || { echo "FAIL K6: the next rollback did not name the restored copy the failed one left (exit $rc): $out"; exit 1; }
# K8, K10: a name the rollback needs that is taken (the state file), and a lock held by another run: refused
fresh k8 && applied && printf '{}' > "$P.rollback-state.json"; refused k8 K8 "records a rollback but cannot be read"; rm -f "$P.rollback-state.json"
chmod a-w "$EVAL_TMP/k8"; refused k8 K8 "is not writable by you"; chmod u+w "$EVAL_TMP/k8"
mkdir "$P.restored-20990101-000001"; ACP_ROLLBACK_TEST=stamp=20990101-000001 refused k8 K8 "$P.restored-20990101-000001 is there already"; rmdir "$P.restored-20990101-000001"
"$PY" -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(300)' "$P/.acp-migration" "$EVAL_TMP/locked" &
lk=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$EVAL_TMP/locked" ] && break; sleep 1; done
refused k8 K10 "another acp migrate is working in"; kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null
# K18: an apply whose put-back could not finish ("stopped, not all put back": here acp layout leaves a file in app/ and
# fails, so app/ cannot be removed) is rolled back from what was really left: an edit after the stop is refused,
# naming it; then the project is restored exactly (backup --check passes, and every entry equals the backup's)
CL="$EVAL_TMP/clone"; cp -R "$PIPELINE_ROOT" "$CL" && perl -0pi -e 's/\n  layout\)\n/\n  layout)\n    case " \$* " in *" --check "*) ;; *) printf x > app\/stray; echo "acp layout: failed here on purpose" >&2; exit 1;; esac\n/' "$CL/bin/acp" \
  && grep -q 'failed here on purpose' "$CL/bin/acp" || { echo "FAIL setup: a clone whose acp layout fails"; exit 1; }
fresh k18 && prepare && out="$(cd "$P" && run "$CL/bin/acp" migrate apply 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "could not put back" <<< "$out" && grep -q '"outcome": "stopped, not all put back"' "$P/.acp-migration/applied.json" && [ -f "$P/.acp-migration/journal.jsonl" ]; } \
  || { echo "FAIL setup: apply did not stop with its put-back unfinished (exit $rc): $out"; exit 1; }
printf '{"kind": "mo' >> "$P/.acp-migration/journal.jsonl"   # a journal whose last line a stop cut short: rollback does not need it
cp -p "$P/README.md" "$EVAL_TMP/readme"; printf 'later\n' >> "$P/README.md"; refused k18 K18 "the project changed after apply: README.md"; cp -p "$EVAL_TMP/readme" "$P/README.md"
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; rc=$?; K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && same "$P" "$K/.acp-migration/manifest.json"; } || { echo "FAIL K18: an apply stopped with its put-back unfinished was not rolled back exactly (exit $rc): $out"; exit 1; }
mkdir "$P/.acp-migration" && cp "$K/.acp-migration/backup.json" "$K/.acp-migration/manifest.json" "$P/.acp-migration/" \
  && (cd "$P" && run "$ACP" migrate backup --check >/dev/null 2>&1) && rm -r "$P/.acp-migration" || { echo "FAIL K18: backup --check does not pass on the rolled-back project"; exit 1; }
# K23: the stops apply records beside the repository (706i: "stopped at <step>", the second commit made or not) take
# the full path like 706h's: here a migrated project recorded as stopped at the moves out of the project
fresh k23 && applied && "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); r.update(outcome="stopped at the moves out of the project", commit_outside=None); json.dump(r, open(sys.argv[1],"w"))' "$P/.acp-migration/applied.json"
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; rc=$?; K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && same "$P" "$K/.acp-migration/manifest.json"; } || { echo "FAIL K23: an apply stopped beside the repository was not rolled back exactly (exit $rc): $out"; exit 1; }
# K19, K20, K21: a real rollback stopped in its swap (ACP_ROLLBACK_TEST, the eval's fault points): a failure says where
# things stand and how to finish (never "running": the run holds the lock itself); a kill, at each rename and between
# the two plain renames (P gone), is found by the next command, from P, with --project, and from the kept tree; and the
# printed finish line, run as it is, completes the rollback exactly
finish() { "$PY" -c 'import re,sys; m = re.search(r"to finish: (.*?)(   \|   |$)", sys.argv[1]); print(m.group(1) if m else "")' "$1"; }
done_ok() { # <id>: P is the backup exactly, and K holds the migrated tree with its record
  local K; K="$(ls -d "$P".pre-rollback-* 2>/dev/null | head -1)"
  { [ -n "$K" ] && [ -f "$K/.acp-migration/rollback.json" ] && same "$P" "$K/.acp-migration/manifest.json"; } || { echo "FAIL $1: the finished rollback is not the backup with the migrated tree kept"; exit 1; }; }
fresh k19 && applied && out="$(cd "$P" && ACP_ROLLBACK_TEST=swapped=fail run "$ACP" migrate rollback 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "the swap stopped" <<< "$out" && grep -qF "to finish:" <<< "$out" && grep -qF "to undo:" <<< "$out" && ! grep -qF "is running" <<< "$out" && mvs_free "$out"; } \
  || { echo "FAIL K19: a swap that failed did not say where things stand (exit $rc): $out"; exit 1; }
f="$(finish "$out")"; (cd "$EVAL_TMP" && sh -c "$f") || { echo "FAIL K19: the printed finish line did not run: $f"; exit 1; }; done_ok K19
fresh k20 && applied && (cd "$P" && ACP_ROLLBACK_TEST=plain,aside=kill run "$ACP" migrate rollback >/dev/null 2>&1); K="$P.pre-rollback-$(ls "$EVAL_TMP/k20" | sed -n 's/^proj\.pre-rollback-//p')"
[ ! -e "$P" ] && [ -d "$K" ] || { echo "FAIL setup: the fallback rollback was not killed between its renames"; exit 1; }
for where in "$EVAL_TMP/k20|--project $P" "$K|"; do d="${where%%|*}"; a="${where#*|}"
  # shellcheck disable=SC2086
  out="$(cd "$d" && run "$ACP" migrate rollback $a 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF "a rollback stopped part-way" <<< "$out" && grep -qF "$P is missing" <<< "$out" && mvs_free "$out"; } \
    || { echo "FAIL K20: a rollback killed with the project moved aside was not found from $d $a (exit $rc): $out"; exit 1; }
done
f="$(finish "$out")"; (cd "$EVAL_TMP" && sh -c "$f") || { echo "FAIL K20: the printed finish line did not run: $f"; exit 1; }; done_ok K20
for pt in created swapped kept; do
  fresh "k21-$pt" && applied && (cd "$P" && ACP_ROLLBACK_TEST="$pt=kill" run "$ACP" migrate rollback >/dev/null 2>&1)
  [ -e "$P.rollback-state.json" ] || { echo "FAIL setup: the rollback was not killed at $pt"; exit 1; }
  out="$(cd "$EVAL_TMP" && run "$ACP" migrate plan --project "$P" 2>&1)"; grep -qF "a rollback stopped part-way" <<< "$out" || { echo "FAIL K21: plan --project did not find the rollback killed at $pt: $out"; exit 1; }
  out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF "a rollback stopped part-way" <<< "$out" && mvs_free "$out"; } || { echo "FAIL K21: a rollback killed at $pt was not reported safely (exit $rc): $out"; exit 1; }
  f="$(finish "$out")"; (cd "$EVAL_TMP" && sh -c "$f") || { echo "FAIL K21: the printed finish line after a kill at $pt did not run: $f"; exit 1; }; done_ok "K21 ($pt)"
done
# K22: an edit while the restored copy is made refuses before the swap, leaving R; an edit to the kept tree while the
# rollback ends is listed as staying there
fresh k22 && applied && out="$(cd "$P" && ACP_ROLLBACK_TEST="copied=append:$P/app/src/main.py" run "$ACP" migrate rollback 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "the project changed while the restored copy was made: app/src/main.py" <<< "$out" && [ -n "$(ls -d "$P".restored-* 2>/dev/null)" ] \
  && [ ! -e "$P.rollback-state.json" ] && [ -z "$(ls -d "$P".pre-rollback-* 2>/dev/null)" ]; } || { echo "FAIL K22: an edit during the restore was not refused before the swap (exit $rc): $out"; exit 1; }
fresh k22b && applied && out="$(cd "$P" && ACP_ROLLBACK_TEST="stamp=20990101-000002,kept=append:$P.pre-rollback-20990101-000002/app/src/main.py" run "$ACP" migrate rollback 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "Changes made while the rollback ran, not in the restored project, stay in $P.pre-rollback-20990101-000002: app/src/main.py" <<< "$out"; } \
  || { echo "FAIL K22: an edit to the kept tree while the rollback ended was not listed (exit $rc): $out"; exit 1; }
# K14: a rollback stopped at each point of the swap (built here as a kill leaves it) is read by inode, from P, from the
# restored copy and from inside the migrated tree, by rollback and by plan: where things stand, never an mv onto a
# name that is taken; a rollback still running is reported as running
stop_at() { # <case> <how>: a migrated project with a restored copy and a state file, renamed as <how> leaves it
  fresh "$1" && applied && local stamp=20990101-000000 R K S; R="$P.restored-$stamp"; K="$P.pre-rollback-$stamp"; S="$P.rollback-state.json"
  mkdir "$R" && tar -xpf "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["backup_archive"])' "$P/.acp-migration/applied.json")" -C "$R" || { echo "FAIL setup: restored copy"; exit 1; }
  "$PY" - "$P" "$R" "$K" "$S" "$2" <<'PYEOF'
import json, os, sys
P, R, K, S, how = sys.argv[1:]
i = lambda p: [os.lstat(p).st_dev, os.lstat(p).st_ino]
step = {"restored": "restored", "swapped": "swapped", "aside": "aside", "kept": "kept-named", "behind": "restored"}[how]
json.dump({"format": 1, "stamp": "20990101-000000", "archive": "a", "P": P, "R": R, "K": K, "migrated": i(P), "restored": i(R), "step": step}, open(S, "w"))
json.dump({"format": 1, "state": S, "stamp": "20990101-000000"}, open(os.path.join(P, ".acp-migration", "rollback-pointer.json"), "w"))
if how in ("swapped", "kept", "behind"): os.rename(P, P + ".t"); os.rename(R, P); os.rename(P + ".t", R)
if how == "kept": os.rename(R, K)
if how == "aside": os.rename(P, K)
PYEOF
}
for how in restored swapped aside kept behind; do
  stop_at "k14-$how" "$how"; R="$P.restored-20990101-000000"; K="$P.pre-rollback-20990101-000000"
  for d in "$P" "$R" "$K"; do [ -d "$d" ] || continue
    for c in rollback plan; do
      out="$(cd "$d" && run "$ACP" migrate "$c" 2>&1)"; rc=$?
      { [ "$rc" -eq 1 ] && grep -qF "a rollback stopped part-way" <<< "$out" && mvs_free "$out"; } || { echo "FAIL K14: $c in $d ($how) did not report the stopped rollback safely (exit $rc): $out"; exit 1; }
    done
  done
done
# the migrated tree moved to another folder after the stop: the pointer inside it still finds the state; a pointer whose
# state is gone, with no record of a finished rollback, says the project was not touched
stop_at k14-moved restored; mkdir -p "$EVAL_TMP/elsewhere" && mv "$P" "$EVAL_TMP/elsewhere/proj"
out="$(cd "$EVAL_TMP/elsewhere/proj" && run "$ACP" migrate plan 2>&1)"; grep -qF "a rollback stopped part-way" <<< "$out" || { echo "FAIL K14: the moved migrated tree did not find its stopped rollback: $out"; exit 1; }
mv "$EVAL_TMP/elsewhere/proj" "$P"; rm -f "$P.rollback-state.json"
out="$(cd "$P" && run "$ACP" migrate plan 2>&1)"; grep -qF "a rollback began here but moved nothing: $P is untouched; remove" <<< "$out" || { echo "FAIL K14: a lone pointer was not explained: $out"; exit 1; }
stop_at k14-last behind; R="$P.restored-20990101-000000"; K="$P.pre-rollback-20990101-000000"
M=""; for d in "$P" "$R" "$K"; do [ -f "$d/.acp-migration/applied.json" ] && M="$d"; done   # the migrated tree, wherever the last case left it
"$PY" -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(300)' "$M/.acp-migration" "$EVAL_TMP/locked2" &
lk=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$EVAL_TMP/locked2" ] && break; sleep 1; done
out="$(cd "$P" && run "$ACP" migrate rollback 2>&1)"; kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null
grep -qF "a rollback is running in" <<< "$out" || { echo "FAIL K14: a rollback holding its lock was not reported as running: $out"; exit 1; }
exit 0
