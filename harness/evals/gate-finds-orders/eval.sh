#!/usr/bin/env bash
# gate-finds-orders: the evidence gate finds the closed orders in the configured folders itself, so an order git
# status does not list (a nested repository, an ignored folder, a skip-worktree or assume-unchanged mark)
# is checked; an old record git tracks as it is stays as it is.
set -uo pipefail
GATE="$PIPELINE_ROOT/core/hooks/evidence-gate.py"
REALGIT="$(command -v git)"; PY="$(command -v python3)"
[ -n "$REALGIT" ] && [ -n "$PY" ] || { echo "FAIL setup: git or python3 not found"; exit 1; }
n=0; SO="$EVAL_TMP/stdout"; W=Workspace/Docs/WorkOrders
G() { "$REALGIT" -c user.name=t -c user.email=t@example.com "$@"; }
PASSED='**Overall status:** EXECUTED — PASS (last run 1)'; FAILED='**Overall status:** EXECUTED — FAIL (last run 1)'
fresh() { n=$((n+1)); R="$EVAL_TMP/r$n"; mkdir -p "$R" && G -C "$R" init -q || { echo "FAIL setup: could not make a scratch repository"; exit 1; }; }
order() { # <folder> <ID> [status line]: a closed order; no status line, no VERIFICATION document
  mkdir -p "$R/$1" && printf '# closeout\n' > "$R/$1/$2-CLOSEOUT.md" || { echo "FAIL setup: could not write $1"; exit 1; }
  [ -z "${3:-}" ] || printf '# V\n\n%s\n' "$3" > "$R/$1/$2-VERIFICATION.md"; }
commit() { G -C "$R" add -A && G -C "$R" commit -qm "$1" || { echo "FAIL setup: could not commit in $R"; exit 1; }; }
fakegit() { # <name> <git subcommand> <what it does instead>: a git that runs the real one for everything else
  mkdir -p "$EVAL_TMP/$1"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = %s ] && { %s; }; done\nexec "%s" "$@"\n' "$2" "$3" "$REALGIT" > "$EVAL_TMP/$1/git"; chmod +x "$EVAL_TMP/$1/git"; }
gate() { # [block] [PATH]: run the gate in ${IN:-$R}; out = its stderr, rc = its exit, $SO its stdout
  out="$(cd "${IN:-$R}" && env PATH="${2:-/usr/bin:/bin}" ${1:+ACP_EVIDENCE_GATE=block} perl -e 'alarm 30; exec @ARGV' "$PY" -I "$GATE" < /dev/null 2>&1 >"$SO")"; rc=$?; }   # a hang ends at 30 s, as a failure
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
now() { "$PY" -c 'import time; print("%.2f" % time.time())'; }
# C1: a failing closed order inside a nested repository blocks, named; the nested repository is still reported
fresh; order "$W/WO-0001-x" WO-0001 "$FAILED"; G -C "$R/Workspace/Docs" init -q
gate block
[ "$rc" -eq 2 ] || { echo "FAIL C1: a failing closed order inside a nested repository passed under block"; exit 1; }
has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL" || { echo "FAIL C1: the gate blocked without naming the order: $out"; exit 1; }
has "Workspace/Docs/: a separate repository; its work orders outside the configured folders are not checked from here" || { echo "FAIL C1: the nested repository was not reported as it now is: $out"; exit 1; }
[ ! -s "$SO" ] || { echo "FAIL C1: the gate wrote its report to stdout, not stderr"; exit 1; }
# C2: a failing closed order in an ignored folder blocks; without block it is reported and does not block
fresh; printf 'Workspace/\n' > "$R/.gitignore"; commit ignore; order "$W/WO-0001-x" WO-0001 "$FAILED"
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C2: a failing closed order in an ignored folder did not block (exit $rc): $out"; exit 1; }
gate ""
{ [ "$rc" -eq 0 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C2: without block the ignored order was not reported, or blocked (exit $rc): $out"; exit 1; }
# C3: a committed passing VERIFICATION marked skip-worktree, or assume-unchanged, and then rewritten to FAIL, blocks
for mark in skip-worktree assume-unchanged; do
  fresh; order "$W/WO-0001-x" WO-0001 "$PASSED"; commit pass
  G -C "$R" update-index "--$mark" "$W/WO-0001-x/WO-0001-VERIFICATION.md" || { echo "FAIL setup: could not mark $mark"; exit 1; }
  printf '# V\n\n%s\n' "$FAILED" > "$R/$W/WO-0001-x/WO-0001-VERIFICATION.md"
  gate block
  { [ "$rc" -eq 2 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C3: a VERIFICATION hidden by $mark did not block (exit $rc): $out"; exit 1; }
done
# C3c: a clean filter that turns FAIL into PASS (git status and the index both say unchanged) does not hide the bytes
fresh; order "$W/WO-0001-x" WO-0001 "$PASSED"; printf '*VERIFICATION.md filter=v\n' > "$R/.gitattributes"; commit filter
G -C "$R" config filter.v.clean 'sed s/FAIL/PASS/'; printf '# V\n\n%s\n' "$FAILED" > "$R/$W/WO-0001-x/WO-0001-VERIFICATION.md"
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C3c: a VERIFICATION hidden by a clean filter did not block (exit $rc): $out"; exit 1; }
# C4: the folders pipeline.config.sh names (a comment after the value, single quotes), from a subfolder too
fresh; printf "export WORKORDERS_DIR='docs/wo'\nexport BUGS_DIR=\"docs/bugs\"   # bugs\n" > "$R/pipeline.config.sh"; printf 'docs/\n' > "$R/.gitignore"; commit config
order docs/bugs/BUG-0001-y BUG-0001 "$FAILED"; order docs/wo/WO-0002-z WO-0002 "$FAILED"; mkdir -p "$R/src"
for IN in "$R" "$R/src"; do
  gate block
  { [ "$rc" -eq 2 ] && has "docs/bugs/BUG-0001-y: the latest verification run is EXECUTED — FAIL" && has "docs/wo/WO-0002-z: the latest verification run is EXECUTED — FAIL"; } \
    || { echo "FAIL C4: an order in a configured folder was not checked from ${IN#$EVAL_TMP/} (exit $rc): $out"; exit 1; }
done; IN=""
# C4b: a project in a subfolder of the repository, its pipeline.config.sh found up from where the gate runs
fresh; mkdir -p "$R/app/src"; printf 'export WORKORDERS_DIR="wo"\n' > "$R/app/pipeline.config.sh"; printf 'wo/\n' > "$R/app/.gitignore"; commit app
order app/wo/WO-0001-x WO-0001 "$FAILED"
IN="$R/app/src" gate block; IN=""
{ [ "$rc" -eq 2 ] && has "app/wo/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C4b: an order in a subfolder project's configured folder was not checked (exit $rc): $out"; exit 1; }
# C5: old records git tracks as they are stay as they are: a committed failing order (with a subfolder),
# and a closed order from before the close guard (a CLOSEOUT, no VERIFICATION) with an ignored .DS_Store beside it
fresh; order "$W/WO-0001-x" WO-0001 "$FAILED"; mkdir -p "$R/$W/WO-0001-x/evidence"; printf 'e\n' > "$R/$W/WO-0001-x/evidence/a"
order "$W/WO-0002-a" WO-0002; printf '.DS_Store\n' > "$R/.gitignore"; commit old; printf 'x' > "$R/$W/WO-0002-a/.DS_Store"
gate block
{ [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$SO" ]; } || { echo "FAIL C5: an old record git tracks as it is was judged again (exit $rc): $out"; exit 1; }
# C6: an ignored CLOSEOUT added to a committed open order blocks
printf '*CLOSEOUT*\n' >> "$R/.gitignore"; commit closeouts-ignored; mkdir -p "$R/$W/WO-0003-b"; printf 'spec\n' > "$R/$W/WO-0003-b/WO-0003-SPEC.md"; commit open
printf '# closeout\n' > "$R/$W/WO-0003-b/WO-0003-CLOSEOUT.md"
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0003-b: CLOSEOUT present, no VERIFICATION document"; } || { echo "FAIL C6: an ignored CLOSEOUT did not block (exit $rc): $out"; exit 1; }
# C5b: a nested repository's own git vouches for its old records: a committed pre-guard PLAN ONLY record stays quiet
fresh; order "$W/WO-0001-x" WO-0001 '**Overall status:** NOT EXECUTED — PLAN ONLY'; G -C "$R/Workspace/Docs" init -q && G -C "$R/Workspace/Docs" add -A && G -C "$R/Workspace/Docs" commit -qm old || { echo "FAIL setup: nested commit"; exit 1; }
gate block
{ [ "$rc" -eq 0 ] && ! has "WO-0001-x"; } || { echo "FAIL C5b: an old record a nested repository vouches for was judged again (exit $rc): $out"; exit 1; }
# C5c: the same nested record changed to FAIL and staged (not committed) is checked
printf '# V\n\n%s\n' "$FAILED" > "$R/$W/WO-0001-x/WO-0001-VERIFICATION.md"; G -C "$R/Workspace/Docs" add -A
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C5c: a staged change in a nested repository's record did not block (exit $rc): $out"; exit 1; }
# C5d: a submodule's record rewritten to FAIL is checked by the submodule's own git
S5="$EVAL_TMP/subsrc"; mkdir -p "$S5" && G -C "$S5" init -q && R0="$R" && R="$S5" && order WorkOrders/WO-0001-x WO-0001 "$PASSED" && commit sub && R="$R0" \
  && fresh && G -c protocol.file.allow=always -C "$R" submodule -q add "$S5" Workspace/Docs >/dev/null 2>&1 && commit submodule || { echo "FAIL setup: could not make a submodule"; exit 1; }
gate block
{ [ "$rc" -eq 0 ] && ! has "WO-0001-x"; } || { echo "FAIL C5d: a passing order in a submodule was not left alone (exit $rc): $out"; exit 1; }
printf '# V\n\n%s\n' "$FAILED" > "$R/$W/WO-0001-x/WO-0001-VERIFICATION.md"
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C5d: a submodule's record rewritten to FAIL did not block (exit $rc): $out"; exit 1; }
# C7: a configured folder that is not a plain path is reported, not guessed; a passing ignored order is quiet
fresh; printf 'export WORKORDERS_DIR="$DOCS_DIR/WO"\n' > "$R/pipeline.config.sh"; commit config
gate block
{ [ "$rc" -eq 0 ] && has "WORKORDERS_DIR in pipeline.config.sh is not a plain path: the orders in it were checked only as git status lists them"; } || { echo "FAIL C7: a configured folder that is not a plain path was not reported, or blocked (exit $rc): $out"; exit 1; }
fresh; printf 'Workspace/\n' > "$R/.gitignore"; commit ignore; order "$W/WO-0001-x" WO-0001 "$PASSED"
gate block
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } || { echo "FAIL C7: a passing order in an ignored folder did not pass quietly (exit $rc): $out"; exit 1; }
# C8: git ls-tree failing, or hanging, blocks with its reason, inside the Stop hook's 10-second limit
order "$W/WO-0002-y" WO-0002 "$FAILED"
fakegit g8 ls-tree 'echo "fatal: bad tree object" >&2; exit 128'
gate block "$EVAL_TMP/g8:/usr/bin:/bin"
{ [ "$rc" -eq 2 ] && has "git ls-tree could not be read (fatal: bad tree object)"; } || { echo "FAIL C8: a failing git ls-tree did not block with its reason (exit $rc): $out"; exit 1; }
mkdir -p "$EVAL_TMP/g8b"; printf '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = rev-parse ] && sleep 2.9; [ "$a" = status ] && sleep 4.8; [ "$a" = ls-tree ] && { sleep 12; exit 0; }; done
exec "%s" "$@"
' "$REALGIT" > "$EVAL_TMP/g8b/git"; chmod +x "$EVAL_TMP/g8b/git"
s="$(now)"; gate block "$EVAL_TMP/g8b:/usr/bin:/bin"; e="$(now)"
[ "$rc" -eq 2 ] || { echo "FAIL C8: a hanging git ls-tree did not block (exit $rc): $out"; exit 1; }
"$PY" -c 'import sys; sys.exit(float(sys.argv[2]) - float(sys.argv[1]) > 9.5)' "$s" "$e" \
  || { echo "FAIL C8: the gate took longer than 9.5 seconds; the Stop hook is killed at 10, and a killed hook does not block"; exit 1; }
# C9: a configured folder the gate cannot list blocks, with its reason
fresh; printf 'Workspace/\n' > "$R/.gitignore"; commit ignore; order "$W/WO-0001-x" WO-0001 "$FAILED"
chmod 000 "$R/$W"; gate block; chmod 755 "$R/$W"
{ [ "$rc" -eq 2 ] && has "$W: the folder cannot be read"; } || { echo "FAIL C9: an unreadable configured folder did not block (exit $rc): $out"; exit 1; }
# C10: a committed linked order folder pointing into an ignored folder is followed and checked
fresh; printf 'store/\n' > "$R/.gitignore"; order store/WO-0001-x WO-0001 "$FAILED"; mkdir -p "$R/$W" && ln -s ../../../store/WO-0001-x "$R/$W/WO-0001-x" && commit link || { echo "FAIL setup: link"; exit 1; }
gate block
{ [ "$rc" -eq 2 ] && has "store/WO-0001-x: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C10: a linked order folder into an ignored folder was not checked (exit $rc): $out"; exit 1; }
# C11: a skip-worktree CLOSEOUT grown to 8 GB (sparse) is not read: its size differs from the committed blob, so the
# order is checked at once, and a failing order beside it still blocks well inside the 10-second limit (S264-6)
fresh; order "$W/WO-0001-a" WO-0001 "$PASSED"; commit old; G -C "$R" update-index --skip-worktree "$W/WO-0001-a/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: mark"; exit 1; }
"$PY" -c 'import sys; f = open(sys.argv[1], "r+b"); f.truncate(8 << 30)' "$R/$W/WO-0001-a/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: could not grow the file"; exit 1; }
order "$W/WO-0002-b" WO-0002 "$FAILED"
s="$(now)"; gate block; e="$(now)"; rm -f "${R:?}/${W:?}/WO-0001-a/WO-0001-CLOSEOUT.md"
{ [ "$rc" -eq 2 ] && has "$W/WO-0002-b: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C11: a huge file beside a failing order did not block (exit $rc): $out"; exit 1; }
"$PY" -c 'import sys; sys.exit(float(sys.argv[2]) - float(sys.argv[1]) > 5)' "$s" "$e" || { echo "FAIL C11: the gate read the huge file instead of comparing its size"; exit 1; }
# C11b: a committed empty CLOSEOUT replaced by a named pipe is never opened (it would wait for ever)
fresh; order "$W/WO-0001-a" WO-0001 "$PASSED"; : > "$R/$W/WO-0001-a/WO-0001-CLOSEOUT.md"; commit old; G -C "$R" update-index --skip-worktree "$W/WO-0001-a/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: mark"; exit 1; }
rm -f "${R:?}/${W:?}/WO-0001-a/WO-0001-CLOSEOUT.md" && mkfifo "$R/$W/WO-0001-a/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: mkfifo"; exit 1; }
order "$W/WO-0002-b" WO-0002 "$FAILED"
gate block
{ [ "$rc" -eq 2 ] && has "$W/WO-0002-b: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C11b: a named pipe in an old order hung the gate or hid a failing order (exit $rc): $out"; exit 1; }
# C12: a file the same size as its 2 GB committed blob must be hashed; with git slow (rev-parse 2.9 s, status 4.8 s,
# ls-tree 0.3 s, so about 0.35 s is left: finishing would take hashing at 5.7 GB/s, S264-9) the
# hashing runs out of time, and the gate stops with that as a problem inside the limit instead of being killed (S264-6)
fresh; order "$W/WO-0001-a" WO-0001 "$PASSED"; commit old
oid="$("$PY" - "$R/.git" <<'PYEOF'
import hashlib, os, sys, zlib
n = 2 << 30; head = b"blob %d\0" % n; z = bytes(1 << 20); c = zlib.compressobj(1); h = hashlib.sha1(head); parts = [c.compress(head)]
for _ in range(n >> 20): h.update(z); parts.append(c.compress(z))
parts.append(c.flush()); oid = h.hexdigest(); d = os.path.join(sys.argv[1], "objects", oid[:2]); os.makedirs(d, exist_ok=True)
with open(os.path.join(d, oid[2:]), "wb") as f: f.write(b"".join(parts))
print(oid)
PYEOF
)" && G -C "$R" update-index --cacheinfo "100644,$oid,$W/WO-0001-a/WO-0001-CLOSEOUT.md" && G -C "$R" update-index --skip-worktree "$W/WO-0001-a/WO-0001-CLOSEOUT.md" \
  && G -C "$R" commit -qm big && "$PY" -c 'import sys; f = open(sys.argv[1], "w+b"); f.truncate(2 << 30)' "$R/$W/WO-0001-a/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: could not make the 2 GB blob"; exit 1; }
mkdir -p "$EVAL_TMP/g12"; printf '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = rev-parse ] && sleep 2.9; [ "$a" = status ] && sleep 4.8; [ "$a" = ls-tree ] && sleep 0.3; done
exec "%s" "$@"
' "$REALGIT" > "$EVAL_TMP/g12/git"; chmod +x "$EVAL_TMP/g12/git"
s="$(now)"; gate block "$EVAL_TMP/g12:/usr/bin:/bin"; e="$(now)"; rm -f "${R:?}/${W:?}/WO-0001-a/WO-0001-CLOSEOUT.md"
# the time runs out while hashing, or, on a slower machine, in one of the git calls before it (git status or ls-tree,
# "(TimeoutExpired): … were not checked"): either way the gate blocks (exit 2) with that as its reason, inside the
# limit, instead of being killed
{ [ "$rc" -eq 2 ] && { has "the closed orders could not all be checked inside the Stop hook's time limit: the rest were not checked" \
    || { has "(TimeoutExpired): " && has " not checked"; }; }; } \
  || { echo "FAIL C12: running out of time while hashing did not block with its reason (exit $rc): $out"; exit 1; }
"$PY" -c 'import sys; sys.exit(float(sys.argv[2]) - float(sys.argv[1]) > 9.5)' "$s" "$e" || { echo "FAIL C12: the gate took longer than 9.5 seconds while hashing; the Stop hook is killed at 10, and a killed hook does not block"; exit 1; }
# C13: a walk-found order whose VERIFICATION is a named pipe, or larger than 64 MB (sparse), is not read: it is a problem
# with its reason, at once, and a failing order beside it still blocks (S264-8: the read waited for ever)
for kind in pipe big; do
  fresh; printf '%s/WO-0001-a/\n' "$W" > "$R/.gitignore"; commit ignore; mkdir -p "$R/$W/WO-0001-a"; printf '# c\n' > "$R/$W/WO-0001-a/WO-0001-CLOSEOUT.md"
  if [ "$kind" = pipe ]; then mkfifo "$R/$W/WO-0001-a/WO-0001-VERIFICATION.md" || { echo "FAIL setup: mkfifo"; exit 1; }
  else printf '# V\n\n%s\n' "$PASSED" > "$R/$W/WO-0001-a/WO-0001-VERIFICATION.md" && "$PY" -c 'import sys; f = open(sys.argv[1], "r+b"); f.truncate(96 << 20)' "$R/$W/WO-0001-a/WO-0001-VERIFICATION.md" || { echo "FAIL setup: grow"; exit 1; }; fi
  order "$W/WO-0002-b" WO-0002 "$FAILED"
  s="$(now)"; gate block; e="$(now)"
  { [ "$rc" -eq 2 ] && has "$W/WO-0001-a: the VERIFICATION document is not a regular file of at most 64 MB; its closeout was not checked" \
    && has "$W/WO-0002-b: the latest verification run is EXECUTED — FAIL"; } || { echo "FAIL C13: a $kind VERIFICATION in a walk-found order was read, or hid the failing order (exit $rc): $out"; exit 1; }
  "$PY" -c 'import sys; sys.exit(float(sys.argv[2]) - float(sys.argv[1]) > 5)' "$s" "$e" || { echo "FAIL C13: the gate took more than 5 seconds over a $kind VERIFICATION"; exit 1; }
done
exit 0
