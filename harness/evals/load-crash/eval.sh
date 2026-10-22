#!/usr/bin/env bash
# load-crash: check.py exits 3, not 1, when a sibling hook module fails to load or one of its values is unusable.
set -uo pipefail
src="$PIPELINE_ROOT/core/hooks"
[ -f "$src/check.py" ] || { echo "FAIL setup: core/hooks/check.py is missing"; exit 1; }
try_broken() { # <name> <file to break> <text to append>
  # the copy keeps bin/sanitize two levels above the hooks, as an install does: the key list lives there
  rm -rf "$EVAL_TMP/$1"; mkdir -p "$EVAL_TMP/$1/core" "$EVAL_TMP/$1/bin" && cp -R "$src" "$EVAL_TMP/$1/core/hooks" && cp "$PIPELINE_ROOT/bin/sanitize" "$EVAL_TMP/$1/bin/"
  printf '\n%s\n' "$3" >> "$EVAL_TMP/$1/core/hooks/$2"
  # run from a repository of its own, so --list has something to list wherever the eval itself runs
  mkdir -p "$EVAL_TMP/$1.repo" && git -C "$EVAL_TMP/$1.repo" init -q || { RC=9; return; }
  (cd "$EVAL_TMP/$1.repo" && python3 "$EVAL_TMP/$1/core/hooks/check.py" --list) >"$EVAL_TMP/$1.out" 2>"$EVAL_TMP/$1.err"; RC=$?
}
# L0: a copy made the way every case below makes one, with nothing broken, runs clean: each break is what fails it
try_broken l0 quality-gate.py '# nothing broken'
[ "$RC" -eq 0 ] || { echo "FAIL L0: an unbroken copy exited $RC, not 0"; cat "$EVAL_TMP/l0.err"; exit 1; }
# L1: a syntax error in a sibling hook
try_broken l1 quality-gate.py 'def (:'
[ "$RC" -eq 3 ] || { echo "FAIL L1: a syntax error in a hook module exited $RC, not 3"; exit 1; }
grep -q '^check: internal error loading the hook modules (SyntaxError: ' "$EVAL_TMP/l1.err" || { echo "FAIL L1: exit 3 without saying why"; exit 1; }
grep -q '^Traceback (most recent call last):' "$EVAL_TMP/l1.err" || { echo "FAIL L1: exit 3 without the traceback"; exit 1; }
# L2: a hook module that raises while it loads
try_broken l2 design-quality.py 'raise RuntimeError("planted")'
[ "$RC" -eq 3 ] || { echo "FAIL L2: a hook module that raised while loading exited $RC, not 3"; exit 1; }
# L3: a value check.py needs at load time is unusable
try_broken l3 quality-gate.py 'SOURCE_EXT = 42'
[ "$RC" -eq 3 ] || { echo "FAIL L3: an unusable hook value exited $RC, not 3"; exit 1; }
# L4: nothing broken: still exits 0
mkdir -p "$EVAL_TMP/proj"; ( cd "$EVAL_TMP/proj" && git init -q && printf 'x = 1\n' > a.py && git add a.py && git -c user.name=t -c user.email=t@example.com commit -qm b )
python3 "$src/check.py" --root "$EVAL_TMP/proj" --paths "$EVAL_TMP/proj/a.py" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL L4: an unbroken check exited $RC, not 0"; exit 1; }
# L5: the module docstring states all four exit codes
grep -q 'when they broke part-way' "$src/check.py" || { echo "FAIL L5: the docstring does not state exit 3"; exit 1; }
grep -q 'Exit 0 when nothing blocks, 2 when something blocks' "$src/check.py" || { echo "FAIL L5: the docstring does not state exits 0 and 2"; exit 1; }
# L6: a hook module that calls exit while loading does not let the checks pass
try_broken l6 evidence-gate.py 'raise SystemExit(0)'
[ "$RC" -eq 3 ] || { echo "FAIL L6: a hook module that exited while loading exited $RC, not 3"; exit 1; }
# L7: programs that import check.py keep their own exit codes when a hook is broken
try_broken l7 quality-gate.py 'SOURCE_EXT = 42'
python3 "$EVAL_TMP/l7/core/hooks/kb.py" status >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL L7: kb.py exited $RC with a broken hook, not its own 1"; exit 1; }
python3 "$EVAL_TMP/l7/core/hooks/inventory.py" --json >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL L7: inventory.py exited $RC with a broken hook, not its own 1"; exit 1; }
exit 0
