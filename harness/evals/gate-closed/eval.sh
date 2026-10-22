#!/usr/bin/env bash
# gate-closed: the evidence gate fails closed under block when git or a work-order folder cannot be read,
# stays out of the way outside a repository, and reports a nested repository it cannot see into.
set -uo pipefail
GATE="$PIPELINE_ROOT/core/hooks/evidence-gate.py"
REALGIT="$(command -v git)"; PY="$(command -v python3)"
[ -n "$REALGIT" ] && [ -n "$PY" ] || { echo "FAIL setup: git or python3 not found"; exit 1; }
n=0; SO="$EVAL_TMP/stdout"
case_repo() { # <status line>: a scratch repository holding one closed order with that status
  n=$((n+1)); R="$EVAL_TMP/r$n"; mkdir -p "$R/Docs/WO-0001-x" && "$REALGIT" -C "$R" init -q || { echo "FAIL setup: could not make a scratch repository"; exit 1; }
  printf '# closeout\n' > "$R/Docs/WO-0001-x/WO-0001-CLOSEOUT.md"; printf '# V\n\n%s\n' "$1" > "$R/Docs/WO-0001-x/WO-0001-VERIFICATION.md"; }
fakegit() { # <name> <git subcommand> <what it does instead>: a git that runs the real one for everything else
  mkdir -p "$EVAL_TMP/$1"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = %s ] && { %s; }; done\nexec "%s" "$@"\n' "$2" "$3" "$REALGIT" > "$EVAL_TMP/$1/git"; chmod +x "$EVAL_TMP/$1/git"; }
gate() { # [block] <PATH> [VAR=value...]: run the gate in ${IN:-$R}; out = its stderr, rc = its exit, $SO its stdout
  local mode="$1" p="$2"; shift 2
  out="$(cd "${IN:-$R}" && env PATH="$p" ${mode:+ACP_EVIDENCE_GATE=block} "$@" "$PY" -I "$GATE" < /dev/null 2>&1 >"$SO")"; rc=$?; }
now() { "$PY" -c 'import time; print("%.2f" % time.time())'; }
took() { # <most seconds> <label>: run gate with the remaining arguments and fail if it took longer
  local most="$1" label="$2" s e; shift 2; s="$(now)"; gate "$@"; e="$(now)"
  "$PY" -c 'import sys; sys.exit(float(sys.argv[2]) - float(sys.argv[1]) > float(sys.argv[3]))' "$s" "$e" "$most" \
    || { echo "FAIL $label: the gate took longer than $most seconds; the Stop hook is killed at 10, and a killed hook does not block"; exit 1; }; }
PASSED='**Overall status:** EXECUTED — PASS (last run 1)'; FAILED='**Overall status:** EXECUTED — FAIL (last run 1)'
# C1: git status failing (a corrupt index, say) blocks under block, with the reason, on stderr
case_repo "$PASSED"; fakegit g1 status 'echo "fatal: index file smaller than expected" >&2; exit 128'
gate block "$EVAL_TMP/g1:/usr/bin:/bin"
[ "$rc" -eq 2 ] || { echo "FAIL C1: the evidence gate passed under block when git status failed (exit $rc)"; exit 1; }
printf '%s\n' "$out" | grep -qF "git status could not be read" || { echo "FAIL C1: the gate blocked without saying git status failed: $out"; exit 1; }
[ ! -s "$SO" ] || { echo "FAIL C1: the gate wrote its report to stdout, not stderr"; exit 1; }
fakegit g1b status 'exit 128'
gate block "$EVAL_TMP/g1b:/usr/bin:/bin"
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "git status could not be read (exit 128)"; } || { echo "FAIL C1: a git status that failed without a word did not block (exit $rc): $out"; exit 1; }
# C2: without block, the same failure is reported but does not block
gate "" "$EVAL_TMP/g1:/usr/bin:/bin"
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "git status could not be read"; } || { echo "FAIL C2: without block the gate did not report git status failing, or blocked (exit $rc)"; exit 1; }
# C3: git status, or git rev-parse, hanging blocks, inside the Stop hook's 10-second limit (both together too)
fakegit g3 status 'sleep 12; exit 0'
took 6 C3 block "$EVAL_TMP/g3:/usr/bin:/bin"
[ "$rc" -eq 2 ] || { echo "FAIL C3: the evidence gate passed under block when git status timed out (exit $rc)"; exit 1; }
fakegit g3b rev-parse 'sleep 12; exit 0'
took 4 C3 block "$EVAL_TMP/g3b:/usr/bin:/bin"
[ "$rc" -eq 2 ] || { echo "FAIL C3: the evidence gate passed under block when git rev-parse timed out (exit $rc)"; exit 1; }
mkdir -p "$EVAL_TMP/g3c"; printf '#!/usr/bin/env bash
for a in "$@"; do [ "$a" = rev-parse ] && sleep 2.9; [ "$a" = status ] && { sleep 12; exit 0; }; done
exec "%s" "$@"
' "$REALGIT" > "$EVAL_TMP/g3c/git"; chmod +x "$EVAL_TMP/g3c/git"
took 9 C3 block "$EVAL_TMP/g3c:/usr/bin:/bin"
[ "$rc" -eq 2 ] || { echo "FAIL C3: the evidence gate passed under block when git rev-parse was slow and git status hung (exit $rc)"; exit 1; }
# C4: inside a repository, no git at all (at its top, in a subfolder, in a worktree's .git file), a git
# that refuses to read it, a .git that cannot be read, or GIT_DIR pointing nowhere, blocks
mkdir -p "$EVAL_TMP/nogit"; ln -s "$PY" "$EVAL_TMP/nogit/python3"
gate block "$EVAL_TMP/nogit"
[ "$rc" -eq 2 ] || { echo "FAIL C4: the evidence gate passed under block with no git inside a repository (exit $rc)"; exit 1; }
printf '%s\n' "$out" | grep -qF "git could not run" || { echo "FAIL C4: the gate blocked without saying git could not run: $out"; exit 1; }
IN="$R/Docs/WO-0001-x" gate block "$EVAL_TMP/nogit"
[ "$rc" -eq 2 ] || { echo "FAIL C4: the evidence gate passed under block with no git, run from a subfolder (exit $rc)"; exit 1; }
fakegit g4 rev-parse 'echo "fatal: detected dubious ownership in repository" >&2; exit 128'
gate block "$EVAL_TMP/g4:/usr/bin:/bin"
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "dubious ownership"; } || { echo "FAIL C4: the evidence gate passed under block when git refused to read the repository (exit $rc): $out"; exit 1; }
chmod 000 "$R/.git"; gate block "/usr/bin:/bin"; chmod 755 "$R/.git"
[ "$rc" -eq 2 ] || { echo "FAIL C4: the evidence gate passed under block when the repository's .git could not be read (exit $rc): $out"; exit 1; }
GIT_DIR=/nonexistent gate block "/usr/bin:/bin"
[ "$rc" -eq 2 ] || { echo "FAIL C4: the evidence gate passed under block with GIT_DIR pointing nowhere (exit $rc): $out"; exit 1; }
mv "$R/.git" "$EVAL_TMP/r${n}-gitdir" && printf 'gitdir: %s\n' "$EVAL_TMP/r${n}-gitdir" > "$R/.git"
gate block "$EVAL_TMP/nogit"
[ "$rc" -eq 2 ] || { echo "FAIL C4: the evidence gate passed under block with no git in a worktree (a .git file) (exit $rc)"; exit 1; }
# C5: outside any repository there is nothing to check: with or without git, under an empty .git
# folder or a .git file that is not git's, or in a folder that has been deleted
mkdir -p "$EVAL_TMP/plain"; R="$EVAL_TMP/plain"
gate block "/usr/bin:/bin"; [ "$rc" -eq 0 ] || { echo "FAIL C5: the gate blocked outside a repository (exit $rc): $out"; exit 1; }
gate block "$EVAL_TMP/nogit"; [ "$rc" -eq 0 ] || { echo "FAIL C5: the gate blocked outside a repository with no git (exit $rc): $out"; exit 1; }
mkdir -p "$EVAL_TMP/o1/.git" "$EVAL_TMP/o1/p"; R="$EVAL_TMP/o1/p"
gate block "/usr/bin:/bin"; [ "$rc" -eq 0 ] || { echo "FAIL C5: the gate blocked under an empty .git folder (exit $rc): $out"; exit 1; }
gate block "$EVAL_TMP/nogit"; [ "$rc" -eq 0 ] || { echo "FAIL C5: the gate blocked under an empty .git folder with no git (exit $rc): $out"; exit 1; }
mkdir -p "$EVAL_TMP/o2/p"; printf 'not git\n' > "$EVAL_TMP/o2/.git"; R="$EVAL_TMP/o2/p"
gate block "/usr/bin:/bin"; [ "$rc" -eq 0 ] || { echo "FAIL C5: the gate blocked under a .git file that is not git's (exit $rc): $out"; exit 1; }
mkdir -p "$EVAL_TMP/gone"; out="$(cd "$EVAL_TMP/gone" && rmdir "$EVAL_TMP/gone" && env PATH="$EVAL_TMP/nogit" ACP_EVIDENCE_GATE=block "$PY" -I "$GATE" < /dev/null 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL C5: the gate crashed or blocked in a folder that was deleted (exit $rc): $out"; exit 1; }
# C6: a work-order folder that cannot be read blocks, with its reason: one the gate cannot list
# (execute-only), and one git itself cannot open (it only warns), in any wording and any locale
case_repo "$FAILED"; "$REALGIT" -C "$R" add -A && "$REALGIT" -C "$R" -c user.name=t -c user.email=t@example.com commit -qm base \
  && printf '# closeout, edited\n' > "$R/Docs/WO-0001-x/WO-0001-CLOSEOUT.md" || { echo "FAIL setup: could not stage C6"; exit 1; }
chmod 100 "$R/Docs/WO-0001-x"; gate block "/usr/bin:/bin"; chmod 755 "$R/Docs/WO-0001-x"
[ "$rc" -eq 2 ] || { echo "FAIL C6: an unreadable work-order folder did not block (exit $rc)"; exit 1; }
printf '%s\n' "$out" | grep -qF "the folder cannot be read" || { echo "FAIL C6: the gate did not say the folder cannot be read: $out"; exit 1; }
case_repo "$FAILED"; chmod 000 "$R/Docs/WO-0001-x"; gate block "/usr/bin:/bin"; chmod 755 "$R/Docs/WO-0001-x"
[ "$rc" -eq 2 ] || { echo "FAIL C6: a folder git could not open did not block (exit $rc)"; exit 1; }
printf '%s\n' "$out" | grep -qF "git could not open" || { echo "FAIL C6: the gate did not say git could not open the folder: $out"; exit 1; }
fakegit g6 status 'echo "warning: could not open directory '"'"'Docs/WO-0009-y/'"'"': Operation not permitted" >&2; exit 0'
gate block "$EVAL_TMP/g6:/usr/bin:/bin"
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "git could not open Docs/WO-0009-y/ (Operation not permitted)"; } || { echo "FAIL C6: a folder git could not open for another reason did not block (exit $rc): $out"; exit 1; }
fakegit g6b status '[ "${LC_ALL:-}" = C ] && echo "warning: could not open directory '"'"'Docs/WO-0009-y/'"'"': Permission denied" >&2 || echo "avertissement : impossible d'"'"'ouvrir le répertoire '"'"'Docs/WO-0009-y/'"'"'" >&2; exit 0'
gate block "$EVAL_TMP/g6b:/usr/bin:/bin" LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF "git could not open Docs/WO-0009-y/"; } || { echo "FAIL C6: under a translated locale a folder git could not open did not block (exit $rc): $out"; exit 1; }
# C7: a nested repository or a submodule is reported under its heading (its work orders are not
# checked from here); a passing order still passes
case_repo "$PASSED"; mkdir -p "$R/vendor/lib" && "$REALGIT" -C "$R/vendor/lib" init -q && printf 'x\n' > "$R/vendor/lib/f"
gate block "/usr/bin:/bin"
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "Not checked from here:" && printf '%s\n' "$out" | grep -qF "vendor/lib/: a separate repository"; } || { echo "FAIL C7: a nested repository was not reported, or blocked (exit $rc): $out"; exit 1; }
G() { "$REALGIT" -c user.name=t -c user.email=t@example.com -c protocol.file.allow=always "$@"; }
S7="$EVAL_TMP/subsrc"; mkdir -p "$S7" && G -C "$S7" init -q && printf 'a\n' > "$S7/f" && G -C "$S7" add f && G -C "$S7" commit -qm s \
  && case_repo "$PASSED" && G -C "$R" add -A && G -C "$R" commit -qm base && G -C "$R" submodule -q add "$S7" sub >/dev/null 2>&1 \
  && G -C "$R" commit -qm sub && printf 'b\n' > "$R/sub/f" || { echo "FAIL setup: could not make a submodule"; exit 1; }
gate block "/usr/bin:/bin"
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "sub: a separate repository"; } || { echo "FAIL C7: a submodule was not reported, or blocked (exit $rc): $out"; exit 1; }
# C8: an ordinary failing order still blocks, and an ordinary passing one passes quietly
case_repo "$FAILED"; gate block "/usr/bin:/bin"; [ "$rc" -eq 2 ] || { echo "FAIL C8: an ordinary failing order no longer blocks"; exit 1; }
case_repo "$PASSED"; gate block "/usr/bin:/bin"; { [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$SO" ]; } || { echo "FAIL C8: an ordinary passing order did not pass quietly (exit $rc): $out"; exit 1; }
exit 0
