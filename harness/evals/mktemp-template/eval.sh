#!/usr/bin/env bash
# mktemp-template: the portability check reports a bare mktemp -d (no template: macOS then ignores TMPDIR),
# and the pipeline's own scripts pass a template, so bin/eval's scratch folders land under TMPDIR.
set -uo pipefail
PC="$PIPELINE_ROOT/bin/maintenance/portability-check.sh"; [ -f "$PC" ] || { echo "FAIL setup: portability-check.sh not found"; exit 1; }
M=mktemp; D=-d   # built here, so this file holds none of the constructs it plants
tree() { rm -rf "$1"; mkdir -p "$1/bin" && printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/bin/x.sh"; }
# B1: each bare form is reported under mktemp-bare, and fails the check
for c in "x=\"\$($M $D)\"" "t=\$($M $D)" "$M $D; echo" "$M -qd" "$M $D -q" "$M $D||true" "$M $D && x" "x=\`$M $D\`" "$M $D 2>/dev/null"; do
  R="$EVAL_TMP/b1"; tree "$R" "$c"
  out="$(bash "$PC" "$R" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "mktemp-bare"; } || { echo "FAIL B1: the portability check did not report a bare mktemp -d"; echo "  case: $c (exit $rc)"; exit 1; }
done
# B2: a template, a template in a variable, and a plain mktemp for a file are not reported by it
for c in "x=\"\$($M $D \"\${TMPDIR:-/tmp}/x.XXXXXX\")\"" "x=\$($M $D \"\$T\")" "f=\"\$($M)\""; do
  R="$EVAL_TMP/b2"; tree "$R" "$c"
  out="$(bash "$PC" "$R" 2>&1)"
  ! printf '%s\n' "$out" | grep -qF "mktemp-bare" || { echo "FAIL B2: the portability check reported a mktemp that has a template, or makes a file: $c"; exit 1; }
done
# B3: bin/eval puts each evaluation's scratch folder under TMPDIR
C="$EVAL_TMP/copy"; mkdir -p "$C" && (cd "$PIPELINE_ROOT" && tar -cf - --exclude ./harness/evals/results --exclude ./.git .) | (cd "$C" && tar -xf -) || { echo "FAIL setup: could not copy the pipeline"; exit 1; }
mkdir -p "$C/harness/evals/zz-probe" "$EVAL_TMP/td" && printf '#!/usr/bin/env bash\ncase "$EVAL_TMP" in "%s"/*) exit 0;; esac\necho "EVAL_TMP=$EVAL_TMP"; exit 1\n' "$EVAL_TMP/td" > "$C/harness/evals/zz-probe/eval.sh"
TMPDIR="$EVAL_TMP/td" bash "$C/bin/eval" run zz-probe >/dev/null 2>&1 || { echo "FAIL B3: bin/eval did not put the evaluation's scratch folder under TMPDIR"; exit 1; }
# B4: the pipeline's own tree is clean under the new rule
out="$(bash "$PC" "$PIPELINE_ROOT" 2>&1)" || { echo "FAIL B4: the pipeline's own tree is not clean: $(printf '%s\n' "$out" | grep -A3 mktemp-bare | head -4)"; exit 1; }
exit 0
