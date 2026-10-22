#!/usr/bin/env bash
# acp migrate backup writes the whole project (.git included) as one tar outside it, with a manifest and a
# record, only once the archive is read back whole and the project is unchanged; it refuses, leaving nothing that
# looks like a backup, on a target inside the project, on anything it cannot read, and on a failed or killed write;
# --check finds a changed archive or manifest.
set -uo pipefail
ACP="$PIPELINE_ROOT/bin/acp"; PY="$(command -v python3)"
G() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
run() { perl -e 'alarm 120; exec @ARGV' "$ACP" migrate backup "$@"; }   # a hang ends at 120 s, as a failure
cleanup() { chmod -R u+rwx "$EVAL_TMP" 2>/dev/null || true; }; trap cleanup EXIT
P="$EVAL_TMP/proj"; R="$P/eng"; BK="$EVAL_TMP/backups"; mkdir -p "$BK" "$EVAL_TMP/outside"
# --- the project, built here ---
mkdir -p "$R/src" "$R/empty" && G -C "$R" init -q || { echo "FAIL setup: git init"; exit 1; }
printf 'export WORKORDERS_DIR="Workspace/Docs/WorkOrders"\n' > "$R/pipeline.config.sh"; printf 'print(1)\n' > "$R/src/main.py"
printf '#!/bin/sh\n' > "$R/src/run.sh" && chmod 755 "$R/src/run.sh"; printf 'same\n' > "$R/src/a.txt" && ln "$R/src/a.txt" "$R/src/hard.txt"
"$PY" -c 'import os, sys; open(sys.argv[1], "wb").write(os.urandom(300000))' "$R/src/blob.bin"
G -C "$R" add -A && G -C "$R" commit -qm base || { echo "FAIL setup: commit"; exit 1; }
mkdir -p "$P/work/tool" && G -C "$P/work/tool" init -q && printf 't\n' > "$P/work/tool/t.txt" && G -C "$P/work/tool" add -A && G -C "$P/work/tool" commit -qm t || { echo "FAIL setup: nested repo"; exit 1; }
printf 'secret\n' > "$EVAL_TMP/outside/secret.txt"; ln -s "$EVAL_TMP/outside" "$P/work/out-link"; ln -s .. "$P/work/up"; ln -s nowhere "$P/work/dangling"
printf 'x\n' > "$P/work/odd
name.txt"
# every entry with its type, mode, size and content (no times: extraction sets its own); links and specials never opened
snap() { "$PY" - "$1" <<'PYEOF'
import hashlib, os, stat, sys
top = sys.argv[1]; rows = []
for dp, dns, fns in os.walk(top, followlinks=False):
    if dp == top and ".acp-migration" in dns: dns.remove(".acp-migration")
    for n in sorted(dns) + sorted(fns):
        p = os.path.join(dp, n); st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode): info = "link " + os.readlink(p)
        elif stat.S_ISREG(st.st_mode):
            with open(p, "rb") as f: info = hashlib.sha256(f.read()).hexdigest()
        elif stat.S_ISDIR(st.st_mode): info = "dir"
        else: info = "special"
        rows.append("%r %o %d %s" % (os.path.relpath(p, top), stat.S_IMODE(st.st_mode), st.st_size if stat.S_ISREG(st.st_mode) else 0, info))
print("\n".join(sorted(rows)))
PYEOF
}
full() { "$PY" - "$P" <<'PYEOF'
import os, stat, sys, hashlib
top = sys.argv[1]; rows = []
for dp, dns, fns in os.walk(top, followlinks=False):
    if dp == top and ".acp-migration" in dns: dns.remove(".acp-migration")
    for n in sorted(dns) + sorted(fns):
        p = os.path.join(dp, n); st = os.lstat(p)
        info = hashlib.sha256(open(p, "rb").read()).hexdigest() if stat.S_ISREG(st.st_mode) else ""
        rows.append("%r %o %d %d %s" % (os.path.relpath(p, top), st.st_mode, st.st_size, st.st_mtime_ns, info))
print("\n".join(sorted(rows)))
PYEOF
}
before="$(full)"; orig="$(snap "$P")"
# B1: the backup is written, outside the project, with its sha256 file, manifest and record, and no .partial left
out="$(cd "$P" && run --to "$BK" 2>&1)"; rc=$?
A="$(ls "$BK"/proj-*.tar 2>/dev/null | head -1)"
{ [ "$rc" -eq 0 ] && [ -n "$A" ] && [ -f "$A.sha256" ] && [ -f "$P/.acp-migration/backup.json" ] && [ -f "$P/.acp-migration/manifest.json" ]; } || { echo "FAIL B1: acp migrate backup did not write a backup"; exit 1; }
grep -qF "Nothing in the project changed." <<< "$out" || { echo "FAIL B1: the backup did not say the project is unchanged: $out"; exit 1; }
[ -z "$(ls "$BK" | grep -F .partial)" ] || { echo "FAIL B1: a .partial file was left"; exit 1; }
# B2: the project is unchanged (every entry, its mode, size, time and content, .git included) outside .acp-migration/
[ "$before" = "$(full)" ] || { echo "FAIL B2: the backup changed the project"; exit 1; }
# B3: the archive restores the project exactly: types, modes, sizes, contents, links as links (the link out of the
# project as a link, its target never archived), the hard link, the empty folder, .git, a name with a newline
X="$EVAL_TMP/restored"; mkdir -p "$X" && "$PY" -c 'import sys, tarfile; t = tarfile.open(sys.argv[1]); t.extractall(sys.argv[2], **({"filter": "fully_trusted"} if hasattr(tarfile, "data_filter") else {}))' "$A" "$X" || { echo "FAIL B3: the archive could not be extracted"; exit 1; }
[ "$orig" = "$(snap "$X")" ] || { echo "FAIL B3: the archive does not restore the project exactly"; exit 1; }
"$PY" -c "import sys, tarfile; n=[m.name for m in tarfile.open(sys.argv[1])]; sys.exit(1 if any('secret' in x for x in n) else 0)" "$A" || { echo "FAIL B3: the archive holds a file from outside the project"; exit 1; }
"$PY" -c 'import os, sys; sys.exit(0 if os.lstat(sys.argv[1]).st_ino == os.lstat(sys.argv[2]).st_ino else 1)' "$X/eng/src/a.txt" "$X/eng/src/hard.txt" || { echo "FAIL B3: the hard link is not restored as one"; exit 1; }
# B4: the record: the archive's sha256 (as recorded, as in its .sha256 file, as computed), the manifest's sha256, the
# entry count, HEAD, the remote state, what was not archived
"$PY" - "$P/.acp-migration" "$A" "$(G -C "$R" rev-parse HEAD)" <<'PYEOF' || { echo "FAIL B4: backup.json does not describe the archive and the manifest as they are"; exit 1; }
import hashlib, json, os, sys
d, a, head = sys.argv[1:]; rec = json.load(open(os.path.join(d, "backup.json"))); mt = open(os.path.join(d, "manifest.json"), "rb").read()
sha = hashlib.sha256(open(a, "rb").read()).hexdigest(); side = open(a + ".sha256").read().split()
ok = rec["archive"] == os.path.realpath(a) and rec["archive_sha256"] == sha and side == [sha, os.path.basename(a)] and rec["archive_bytes"] == os.path.getsize(a) \
  and rec["manifest_sha256"] == hashlib.sha256(mt).hexdigest() and rec["entries"] == len(json.loads(mt)["entries"]) and rec["head"] == head \
  and rec["remote"] == {"exists": False, "pushed": False}
sys.exit(0 if ok else 1)
PYEOF
# B5: --check finds the backup whole; then a changed archive, and a changed manifest, are found
out="$(cd "$P" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qF "is whole:" <<< "$out"; } || { echo "FAIL B5: --check did not find the backup whole (exit $rc): $out"; exit 1; }
cp "$P/.acp-migration/manifest.json" "$EVAL_TMP/manifest.keep"; printf ' ' >> "$P/.acp-migration/manifest.json"
out="$(cd "$P" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: manifest.json is not the one the backup recorded" <<< "$out"; } || { echo "FAIL B5: --check did not find the manifest changed (exit $rc): $out"; exit 1; }
cp "$EVAL_TMP/manifest.keep" "$P/.acp-migration/manifest.json"; printf 'x' >> "$A"
out="$(cd "$P" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: the archive $(cd "$BK" && pwd -P)/$(basename "$A") is not the one recorded: its sha256 differs" <<< "$out"; } || { echo "FAIL B5: --check did not find the archive changed (exit $rc): $out"; exit 1; }
# B5b: an archive whose member was changed and whose sha256 was re-recorded to match is still found: every entry is
# read back against the manifest
"$PY" - "$A" "$P/.acp-migration/backup.json" <<'PYEOF' || { echo "FAIL setup: could not rewrite the archive"; exit 1; }
import hashlib, io, json, os, sys, tarfile
a, rp = sys.argv[1:]; src = tarfile.open(a); tmp = a + ".re"
with tarfile.open(tmp, "w", format=tarfile.PAX_FORMAT) as out:
    for m in src:
        data = src.extractfile(m).read() if m.isreg() else None
        if m.name == "eng/src/main.py": data = b"print(2)\n"
        out.addfile(m, io.BytesIO(data) if data is not None else None)
os.replace(tmp, a); sha = hashlib.sha256(open(a, "rb").read()).hexdigest()
open(a + ".sha256", "w").write(f"{sha}  {os.path.basename(a)}\n"); r = json.load(open(rp)); r["archive_sha256"] = sha; r["archive_bytes"] = os.path.getsize(a); json.dump(r, open(rp, "w"))
PYEOF
out="$(cd "$P" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: eng/src/main.py is not archived as it was" <<< "$out"; } || { echo "FAIL B5b: --check did not find a changed entry in a re-recorded archive (exit $rc): $out"; exit 1; }
# a second project for the refusals: each exit 1 with its line, nothing written in the target or the project
Q="$EVAL_TMP/q"; mkdir -p "$Q/src" && G -C "$Q" init -q && : > "$Q/pipeline.config.sh" && printf 'a\n' > "$Q/src/a.txt" && G -C "$Q" add -A && G -C "$Q" commit -qm q || { echo "FAIL setup: q"; exit 1; }
RQ="$(cd "$Q" && pwd -P)"; T2="$EVAL_TMP/t2"; mkdir -p "$T2"; RT2="$(cd "$T2" && pwd -P)"
refused() { # <case> <expected line> <args...>
  local c="$1" want="$2"; shift 2; out="$(cd "$Q" && run "$@" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qxF -- "$want" <<< "$out"; } || { echo "FAIL $c: expected exit 1 and '$want' (exit $rc): $out"; exit 1; }
  { [ -z "$(ls -A "$T2")" ] && [ ! -e "$Q/.acp-migration/backup.json" ]; } || { echo "FAIL $c: a refused backup left something behind"; exit 1; }; }
# B6: a target inside the project, also through a link; a missing target; no target
mkdir -p "$Q/inside"; ln -s "$Q/inside" "$EVAL_TMP/via-link"
refused B6 "acp migrate backup: $RQ/inside is inside the project; the backup must be kept outside it" --to "$Q/inside"
refused B6 "acp migrate backup: $RQ/inside is inside the project; the backup must be kept outside it" --to "$EVAL_TMP/via-link"
refused B6 "acp migrate backup: $RQ is inside the project; the backup must be kept outside it" --to "$Q"
refused B6 "acp migrate backup: $(cd "$EVAL_TMP" && pwd -P)/nowhere is not a folder" --to "$EVAL_TMP/nowhere"
refused B6 "acp migrate backup: name the folder outside the project to write the backup into: --to <dir>"
rmdir "$Q/inside"
# B7: something in the project that cannot be read: a file, and a folder
printf 's\n' > "$Q/src/locked.txt" && chmod 000 "$Q/src/locked.txt"
refused B7 "acp migrate backup: these cannot be read, so a backup would miss them: src/locked.txt (Permission denied)" --to "$T2"
chmod 644 "$Q/src/locked.txt"; mkdir -p "$Q/sealed" && chmod 000 "$Q/sealed"
refused B7 "acp migrate backup: these cannot be read, so a backup would miss them: sealed (Permission denied)" --to "$T2"
chmod 755 "$Q/sealed"
# B7b: a special file (a pipe, a socket) refuses: a backup cannot copy it whole
mkfifo "$Q/src/pipe" || { echo "FAIL setup: mkfifo"; exit 1; }
refused B7b "acp migrate backup: src/pipe is a special file (a pipe, socket or device); a backup copies files, folders and links only, so remove it first" --to "$T2"
rm -f "${Q:?}/src/pipe"; (cd "$Q/src" && "$PY" -c 'import socket; s = socket.socket(socket.AF_UNIX); s.bind("sock")') || { echo "FAIL setup: socket"; exit 1; }   # bound by its short name: a socket path has a short limit
refused B7b "acp migrate backup: src/sock is a special file (a pipe, socket or device); a backup copies files, folders and links only, so remove it first" --to "$T2"
rm -f "${Q:?}/src/sock"
# B8: a write that fails part-way (the file size limit, as a full disk would) keeps nothing; a write killed part-way
# leaves only the .partial file, never an archive under its final name, its .sha256, or a record
"$PY" -c 'import os, sys; open(sys.argv[1], "wb").write(os.urandom(2000000))' "$Q/src/big.bin"
out="$(cd "$Q" && (trap '' XFSZ; ulimit -f 512; "$ACP" migrate backup --to "$T2") 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "acp migrate backup: the archive could not be written (" <<< "$out" && grep -qF "); nothing was kept" <<< "$out"; } || { echo "FAIL B8: a write that failed part-way did not refuse with its reason (exit $rc): $out"; exit 1; }
{ [ -z "$(ls -A "$T2")" ] && [ ! -e "$Q/.acp-migration/backup.json" ]; } || { echo "FAIL B8: a write that failed part-way left something behind: $(ls -A "$T2")"; exit 1; }
# killed: SIGKILL as soon as the archive file appears in the target (python ignores SIGXFSZ, so a file limit cannot kill it)
"$PY" -c 'import os, sys; open(sys.argv[1], "wb").write(os.urandom(40000000))' "$Q/src/big.bin"
"$PY" - "$Q" "$T2" "$ACP" <<'PYEOF' || { echo "FAIL setup: the backup could not be killed part-way"; exit 1; }
import os, signal, subprocess, sys, time
q, t, acp = sys.argv[1:]
p = subprocess.Popen([acp, "migrate", "backup", "--to", t], cwd=q, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
end = time.time() + 30
while time.time() < end and p.poll() is None:
    if any(os.path.getsize(os.path.join(t, n)) > 0 for n in os.listdir(t)): break
    time.sleep(0.01)
if p.poll() is not None: sys.exit(1)   # it finished, or failed, before it could be killed: the case did not happen
os.killpg(p.pid, signal.SIGKILL); p.wait()
PYEOF
{ [ -z "$(ls "$T2" | grep -v '\.partial$')" ] && [ ! -e "$Q/.acp-migration/backup.json" ]; } || { echo "FAIL B8: a killed backup left an archive under the final name, looking whole"; exit 1; }
# B10: the project changing while the backup is written is refused, and nothing that looks like a backup is kept: a
# file already archived (src/a.txt) changes after the archive is written and read back, which only the fresh walk after
# the write can see. Deterministic: the change is made at that point, inside the run, not raced against it.
rm -rf "${T2:?}"/*
out="$(cd "$Q" && "$PY" - "$PIPELINE_ROOT/core/hooks" "$T2" <<'PYEOF' 2>&1
import sys
sys.path.insert(0, sys.argv[1]); import migrate
real = migrate.check_archive
def check_then_change(archive, rows):
    real(archive, rows)
    with open("src/a.txt", "a") as f: f.write("changed\n")   # after the read-back, before the fresh walk
migrate.check_archive = check_then_change
sys.exit(migrate.main(["backup", "--to", sys.argv[2]]))
PYEOF
)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "acp migrate backup: the project changed while the backup was written: src/a.txt" <<< "$out" && [ -z "$(ls -A "$T2")" ] && [ ! -e "$Q/.acp-migration/backup.json" ]; } \
  || { echo "FAIL B10: a project changed during the backup was not refused, or left something behind (rc $rc): $(ls -A "$T2") $out"; exit 1; }
"$PY" -c 'import sys; open(sys.argv[1], "w").write("a\n")' "$Q/src/a.txt"
# B18: a failure after the archive has its final name (writing the record) removes the archive, its .sha256 and the
# manifest it wrote: a refused backup never leaves anything that looks like one
rm -rf "${T2:?}"/*
out="$(cd "$Q" && "$PY" - "$PIPELINE_ROOT/core/hooks" "$T2" <<'PYEOF' 2>&1
import errno, sys
sys.path.insert(0, sys.argv[1]); import migrate
real = migrate.backup_put
def put(d, name, text):
    if name == "backup.json": raise OSError(errno.ENOSPC, "No space left on device")   # the disk fills at the very last write
    real(d, name, text)
migrate.backup_put = put
sys.exit(migrate.main(["backup", "--to", sys.argv[2]]))
PYEOF
)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "acp migrate backup: the backup's record could not be written (No space left on device); nothing was kept" <<< "$out" && [ -z "$(ls -A "$T2")" ] \
  && [ ! -e "$Q/.acp-migration/backup.json" ] && [ ! -e "$Q/.acp-migration/manifest.json" ]; } \
  || { echo "FAIL B18: a backup refused after the rename left something behind (rc $rc): $(ls -A "$T2") $(ls -A "$Q/.acp-migration" 2>/dev/null) $out"; exit 1; }
# B9: a linked .acp-migration, or a linked record, is never written through
rm -rf "${T2:?}"/* ; mkdir -p "$EVAL_TMP/elsewhere"; rm -rf "${Q:?}/.acp-migration"; ln -s "$EVAL_TMP/elsewhere" "$Q/.acp-migration"
refused B9 "acp migrate backup: $RQ/.acp-migration is a link or not a folder; remove it first" --to "$T2"
[ -z "$(ls -A "$EVAL_TMP/elsewhere")" ] || { echo "FAIL B9: a linked .acp-migration was written through"; exit 1; }
# B11: a target that is the project or inside it, however it is spelled: in another letter case (where the file
# system ignores case), or through the macOS firmlink /System/Volumes/Data; judged by device and inode
Z="$EVAL_TMP/zz"; mkdir -p "$Z/src" && G -C "$Z" init -q && : > "$Z/pipeline.config.sh" && printf 'a\n' > "$Z/src/a.txt" && G -C "$Z" add -A && G -C "$Z" commit -qm z && mkdir -p "$Z/inside" || { echo "FAIL setup: zz"; exit 1; }
RZ="$(cd "$Z" && pwd -P)"; T3="$EVAL_TMP/t3"; mkdir -p "$T3"
# an archive is named by the second, and a run whose name is taken refuses before anything else: a run meant to reach a
# later step waits until the clock has passed the newest archive's second
later() { "$PY" -c 'import glob, os, sys, time
from datetime import datetime
last = max(os.path.basename(p)[3:18] for p in glob.glob(os.path.join(sys.argv[1], "zz-*.tar")))
while datetime.now().strftime("%Y%m%d-%H%M%S") <= last: time.sleep(0.05)' "$T3"; }
inside() { # <case> <--to spelling>
  out="$(cd "$Z" && run --to "$2" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qF "is inside the project; the backup must be kept outside it" <<< "$out" && [ ! -e "$Z/.acp-migration/backup.json" ] && [ -z "$(ls -A "$Z/inside")" ]; } || { echo "FAIL $1: a backup target inside the project, spelled $2, was not refused (exit $rc): $out"; exit 1; }; }
if [ -d "$(dirname "$Z")/ZZ" ]; then inside B11 "$(dirname "$Z")/ZZ/inside"; fi   # a file system that ignores case
if [ -d "/System/Volumes/Data$RZ" ]; then inside B11 "/System/Volumes/Data$RZ/inside"; fi   # the macOS data-volume firmlink
rmdir "$Z/inside"
# B12: a repository whose data lives outside the project is refused, not called whole: a linked worktree, and a
# clone that borrows another repository's objects (--shared)
O="$EVAL_TMP/origin"; mkdir -p "$O" && G -C "$O" init -q && printf 'o\n' > "$O/o.txt" && G -C "$O" add -A && G -C "$O" commit -qm o || { echo "FAIL setup: origin"; exit 1; }
G -C "$O" worktree add -q "$Z/wt" -b wt >/dev/null 2>&1 || { echo "FAIL setup: worktree"; exit 1; }
out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "acp migrate backup: a repository in the project keeps data outside it, so a backup would not hold it: wt/.git (names " <<< "$out" && [ -z "$(ls -A "$T3")" ]; } || { echo "FAIL B12: a linked worktree was not refused (exit $rc): $out"; exit 1; }
rm -rf "${Z:?}/wt"; G -C "$O" worktree prune
G clone -q --shared "$O" "$Z/borrowed" 2>/dev/null || { echo "FAIL setup: shared clone"; exit 1; }
out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "borrowed/.git/objects/info/alternates (names " <<< "$out" && [ -z "$(ls -A "$T3")" ]; } || { echo "FAIL B12: a clone borrowing objects from outside was not refused (exit $rc): $out"; exit 1; }
rm -rf "${Z:?}/borrowed"
# B13: a record never outlives what it describes: a later run that fails removes the earlier record first; --check
# finds a project changed since the backup, a record that does not match its manifest, one that cannot be read, a
# .sha256 that does not match, and an archive replaced by a link
out="$(cd "$Z" && run --to "$T3" 2>&1)" || { echo "FAIL setup: zz backup: $out"; exit 1; }
AZ="$(ls "$T3"/zz-*.tar | head -1)"; cp "$Z/.acp-migration/backup.json" "$EVAL_TMP/zz-backup.json"; cp "$Z/.acp-migration/manifest.json" "$EVAL_TMP/zz-manifest.json"
checks() { # <case> <expected line>
  out="$(cd "$Z" && run --check 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -qxF -- "$2" <<< "$out"; } || { echo "FAIL $1: --check did not refuse with '$2' (exit $rc): $out"; exit 1; }; }
restore() { cp "$EVAL_TMP/zz-backup.json" "$Z/.acp-migration/backup.json"; cp "$EVAL_TMP/zz-manifest.json" "$Z/.acp-migration/manifest.json"; }
keep() { "$PY" -c 'import json, os, sys; st = os.stat(sys.argv[1]); print(json.dumps([open(sys.argv[1], "rb").read().decode("latin-1"), st.st_atime_ns, st.st_mtime_ns]))' "$1"; }
back() { "$PY" -c 'import json, os, sys; d, a, m = json.loads(sys.argv[2]); f = open(sys.argv[1], "r+b"); f.write(d.encode("latin-1")); f.truncate(); f.close(); os.utime(sys.argv[1], ns=(a, m))' "$1" "$2"; }
k="$(keep "$Z/src/a.txt")"; printf 'changed\n' >> "$Z/src/a.txt"; checks B13 "acp migrate backup: the project has changed since the backup: src/a.txt"
back "$Z/src/a.txt" "$k"   # the same bytes and times, written in place
"$PY" -c 'import json, sys; r = json.load(open(sys.argv[1])); r["entries"] += 1; json.dump(r, open(sys.argv[1], "w"))' "$Z/.acp-migration/backup.json"
checks B13 "acp migrate backup: backup.json does not describe this project's manifest"; restore
printf '{"half' > "$Z/.acp-migration/backup.json"; checks B13 "acp migrate backup: the backup record in $RZ/.acp-migration cannot be read (JSONDecodeError)"; restore
cp "$AZ.sha256" "$EVAL_TMP/zz.sha256"; printf '0%.0s' $(seq 64) > "$AZ.sha256"; checks B13 "acp migrate backup: $(cd "$T3" && pwd -P)/$(basename "$AZ").sha256 does not match"; cp "$EVAL_TMP/zz.sha256" "$AZ.sha256"
mv "$AZ" "$AZ.real" && ln -s "$AZ.real" "$AZ"; checks B13 "acp migrate backup: the archive $(cd "$T3" && pwd -P)/$(basename "$AZ") is not there (or is not a regular file)"; rm -f "$AZ"; mv "$AZ.real" "$AZ"
out="$(cd "$Z" && run --check 2>&1)" || { echo "FAIL B13: the restored backup does not check whole: $out"; exit 1; }
"$PY" -c 'import os, sys; open(sys.argv[1], "wb").write(os.urandom(2000000))' "$Z/src/big.bin"
later; out="$(cd "$Z" && (trap '' XFSZ; ulimit -f 512; "$ACP" migrate backup --to "$T3") 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: the archive could not be written (File too large); nothing was kept" <<< "$out"; } \
  || { echo "FAIL B13: the later backup did not fail where the file size limit stops it (exit $rc): $out"; exit 1; }
[ ! -e "$Z/.acp-migration/backup.json" ] || { echo "FAIL B13: a later backup that failed left the earlier record saying the backup is whole"; exit 1; }
# B14: a refused run leaves a record that is still true; --check reads the .sha256 line whole and the archive's size;
# a hard link archived to the wrong file and an entry missing from the archive are found though the archive's sha256
# is re-recorded to match; a link out of a bare repository in the project refuses
ln "$Z/src/a.txt" "$Z/src/hard.txt" || { echo "FAIL setup: hard link"; exit 1; }
out="$(cd "$Z" && run --to "$T3" 2>&1)" || { echo "FAIL setup: zz backup 2: $out"; exit 1; }
AZ="$(ls -t "$T3"/zz-*.tar | head -1)"; cp "$Z/.acp-migration/backup.json" "$EVAL_TMP/zz2-backup.json"
out="$(cd "$Z" && run --to "$Z/src" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -f "$Z/.acp-migration/backup.json" ]; } || { echo "FAIL B14: a refused run removed a record that was still true (exit $rc): $out"; exit 1; }
out="$(cd "$Z" && run --check 2>&1)" || { echo "FAIL B14: the second backup does not check whole: $out"; exit 1; }
cp "$AZ.sha256" "$EVAL_TMP/zz2.sha256"; sed 's/  .*/  another-name.tar/' "$EVAL_TMP/zz2.sha256" > "$AZ.sha256"
checks B14 "acp migrate backup: $(cd "$T3" && pwd -P)/$(basename "$AZ").sha256 does not match"; cp "$EVAL_TMP/zz2.sha256" "$AZ.sha256"
"$PY" -c 'import json, sys; r = json.load(open(sys.argv[1])); r["archive_bytes"] += 1; json.dump(r, open(sys.argv[1], "w"))' "$Z/.acp-migration/backup.json"
checks B14 "acp migrate backup: $(cd "$T3" && pwd -P)/$(basename "$AZ").sha256 does not match"; cp "$EVAL_TMP/zz2-backup.json" "$Z/.acp-migration/backup.json"
rewrite() { # <python body over members m, writing to out>: rewrite the archive, re-recording its sha256 and size
  "$PY" - "$AZ" "$Z/.acp-migration/backup.json" "$1" <<'PYEOF' || { echo "FAIL setup: could not rewrite the archive"; exit 1; }
import hashlib, io, json, os, sys, tarfile
a, rp, body = sys.argv[1:]; src = tarfile.open(a); tmp = a + ".re"; members = [(m, src.extractfile(m).read() if m.isreg() else None) for m in src]
with tarfile.open(tmp, "w", format=tarfile.PAX_FORMAT) as out: exec(body)
os.replace(tmp, a); sha = hashlib.sha256(open(a, "rb").read()).hexdigest()
open(a + ".sha256", "w").write(f"{sha}  {os.path.basename(a)}\n"); r = json.load(open(rp)); r["archive_sha256"] = sha; r["archive_bytes"] = os.path.getsize(a); json.dump(r, open(rp, "w"))
PYEOF
}
cp "$AZ" "$EVAL_TMP/zz2.tar"; cp "$AZ.sha256" "$EVAL_TMP/zz2.sha256"
rewrite 'for m, d in members: out.addfile(m, io.BytesIO(d) if d is not None else None) if m.name != "src/big.bin" else None'
checks B14 "acp migrate backup: the archive is missing src/big.bin"
cp "$EVAL_TMP/zz2.tar" "$AZ"; cp "$EVAL_TMP/zz2.sha256" "$AZ.sha256"; cp "$EVAL_TMP/zz2-backup.json" "$Z/.acp-migration/backup.json"
rewrite '
for m, d in members:
    if m.name == "src/hard.txt": m.linkname = "src/big.bin"   # the hard link now names another file
    out.addfile(m, io.BytesIO(d) if d is not None else None)'
checks B14 "acp migrate backup: src/hard.txt is not archived as it was"
cp "$EVAL_TMP/zz2.tar" "$AZ"; cp "$EVAL_TMP/zz2.sha256" "$AZ.sha256"; cp "$EVAL_TMP/zz2-backup.json" "$Z/.acp-migration/backup.json"
G clone -q --bare "$O" "$Z/kept.git" 2>/dev/null && ln -s "$EVAL_TMP/origin/.git/refs/heads" "$Z/kept.git/refs/outside" || { echo "FAIL setup: bare with a link"; exit 1; }
later; out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "kept.git/refs/outside (a link to " <<< "$out"; } || { echo "FAIL B14: a link out of a bare repository was not refused (exit $rc): $out"; exit 1; }
rm -rf "${Z:?}/kept.git"
# a run refused after the walk (a pipe in the project) keeps the earlier record: it was still true when the run began
mkfifo "$Z/pipe" || { echo "FAIL setup: mkfifo"; exit 1; }
later; out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?; rm -f "${Z:?}/pipe"
{ [ "$rc" -eq 1 ] && grep -qF "pipe is a special file" <<< "$out" && [ -f "$Z/.acp-migration/backup.json" ]; } || { echo "FAIL B14: a run refused after the walk removed the earlier record (exit $rc): $out"; exit 1; }
# B15: once an apply has run, a backup would describe the migrated tree: refused; a running apply (its lock) refuses a
# backup; a mount inside the project refuses; the success line says to run nothing else until apply
later; out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -qxF "  Run nothing but acp migrate in the project until apply: any other git command can change .git, and apply then refuses." <<< "$out"; } || { echo "FAIL B15: the success line does not say to run nothing else until apply (exit $rc): $out"; exit 1; }
printf '{}\n' > "$Z/.acp-migration/applied.json"
out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?; rm -f "$Z/.acp-migration/applied.json"
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: an apply has run here (.acp-migration/applied.json); a new backup would describe the migrated tree. Roll back first, or start again from a fresh copy" <<< "$out"; } \
  || { echo "FAIL B15: a backup after an apply was not refused (exit $rc): $out"; exit 1; }
"$PY" -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' "$Z/.acp-migration" "$EVAL_TMP/held" & HOLD=$!
i=0; while [ ! -e "$EVAL_TMP/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
out="$(cd "$Z" && run --to "$T3" 2>&1)"; rc=$?; kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
{ [ "$rc" -eq 1 ] && grep -qxF "acp migrate backup: another acp migrate is working in $RZ/.acp-migration; wait for it to finish, then run this again" <<< "$out"; } || { echo "FAIL B15: a backup ran while another held the lock (exit $rc): $out"; exit 1; }
"$PY" - "$Z" "$PIPELINE_ROOT/core/hooks" <<'PYEOF' || { echo "FAIL B15: a folder on another device inside the project is not found"; exit 1; }
import os, sys
sys.path.insert(0, sys.argv[2]); import migrate
real = os.lstat
class St:   # src as if a filesystem were mounted there: its device differs from the project's
    def __init__(self, st): self.st, self.st_dev = st, st.st_dev + 1
os.lstat = lambda p, *a, **k: St(real(p)) if p.rstrip("/").endswith("/src") else real(p, *a, **k)
sys.exit(0 if migrate.mounts_in(sys.argv[1], [{"path": "src", "type": "dir"}, {"path": "src/a.txt", "type": "file"}]) == ["src"] else 1)
PYEOF
# B16: git's own housekeeping is not a change: after a gc packs the loose objects, --check still passes, since .git is
# judged by its refs, HEAD, config, hooks, info and reachable objects. A new commit is a change, named as one. A record
# made before that (no "git" in backup.json) keeps the byte-for-byte compare, and says so.
later; out="$(cd "$Z" && run --to "$T3" 2>&1)" || { echo "FAIL setup: B16 backup: $out"; exit 1; }
[ -n "$(find "$Z/.git/objects" -type f -path '*/objects/??/*' | head -1)" ] || { echo "FAIL setup: B16 has no loose objects to pack"; exit 1; }
git -C "$Z" gc -q --prune=now 2>/dev/null && [ -z "$(find "$Z/.git/objects" -type f -path '*/objects/??/*' | head -1)" ] || { echo "FAIL setup: git gc did not pack the loose objects"; exit 1; }
out="$(cd "$Z" && run --check 2>&1)" || { echo "FAIL B16: --check refused once git gc had packed the loose objects: $out"; exit 1; }
cp "$Z/.acp-migration/backup.json" "$EVAL_TMP/b16.json"
"$PY" -c 'import json, sys; r = json.load(open(sys.argv[1])); r.pop("git"); json.dump(r, open(sys.argv[1], "w"), indent=1, sort_keys=True)' "$Z/.acp-migration/backup.json"
out="$(cd "$Z" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "(this backup judges .git byte for byte; a new backup judges it by its refs and objects)" <<< "$out"; } || { echo "FAIL B16: an older record did not keep the byte-for-byte compare (exit $rc): $out"; exit 1; }
cp "$EVAL_TMP/b16.json" "$Z/.acp-migration/backup.json"
G -C "$Z" commit -q --allow-empty -m after
out="$(cd "$Z" && run --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && grep -qF "acp migrate backup: the repository has changed since the backup: .git: refs refs/heads/main moved" <<< "$out"; } || { echo "FAIL B16: a commit after the backup was not refused as a change (exit $rc): $out"; exit 1; }
# B17: a file that vanishes while a comparing walk reads it, under a git directory's objects/, is left out; the same
# under a backup's own walk, or anywhere else, refuses, naming the file and why
"$PY" - "$Z" "$PIPELINE_ROOT/core/hooks" <<'PYEOF' || exit 1
import os, sys
sys.path.insert(0, sys.argv[2]); import migrate
z = sys.argv[1]
def vanishing(rel):   # this one file is gone when the walk reaches it, as a gc would leave it
    real = os.lstat
    def lstat(p, *a, **k):
        if os.path.relpath(p, z) == rel: raise FileNotFoundError(2, "No such file or directory", p)
        return real(p, *a, **k)
    return lstat
obj = next(os.path.relpath(os.path.join(d, f), z) for d, _, fs in os.walk(os.path.join(z, ".git", "objects")) for f in fs)
real = os.lstat
os.lstat = vanishing(obj)
rows = migrate.manifest_of(z, vanish_ok=True)
if any(r["path"] == obj for r in rows): print("FAIL B17: a vanished object file was kept in a comparing walk"); sys.exit(1)
try: migrate.manifest_of(z); print("FAIL B17: a backup's own walk passed over a vanished object file"); sys.exit(1)
except migrate.Refusal as e:
    if f"{obj} (it vanished while being read" not in str(e): print("FAIL B17: the refusal does not name the vanished file and why:", e); sys.exit(1)
os.lstat = vanishing(os.path.join("src", "a.txt"))
try: migrate.manifest_of(z, vanish_ok=True); print("FAIL B17: a product file that vanished was passed over"); sys.exit(1)
except migrate.Refusal as e:
    if "src/a.txt (it vanished while being read" not in str(e): print("FAIL B17: the refusal does not name the product file and why:", e); sys.exit(1)
PYEOF
exit 0
