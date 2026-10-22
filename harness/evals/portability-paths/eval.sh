#!/usr/bin/env bash
# portability-paths: the portability check reads its file list as data, so a script under a path holding a space
# or a | is checked, not reported clean; the grep-perl rule also names lzgrep and zstdgrep.
set -uo pipefail
PC="$PIPELINE_ROOT/bin/maintenance/portability-check.sh"; [ -f "$PC" ] || { echo "FAIL setup: portability-check.sh not found"; exit 1; }
tree() { mkdir -p "$1/bin" && printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/bin/x.sh"; }
G=grep; P=-P; GP="$G $P \"x\" file"   # built here, so this file holds none of the constructs it plants
# T1: a script under a root holding a space is checked: its perl-regex grep is reported, and the check fails
R="$EVAL_TMP/a b/root"; tree "$R" "$GP"
out="$(bash "$PC" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "grep-perl" && printf '%s\n' "$out" | grep -qF "bin/x.sh:2:"; } \
  || { echo "FAIL T1: a script under a path holding a space was not checked (exit $rc)"; printf '  %s\n' "$out" | head -3; exit 1; }
# T2: a root holding |, [1] or # is checked and its findings are named from the root down
for q in 'p|q' 'g[1]' 'h#k'; do
  R="$EVAL_TMP/$q/root"; tree "$R" "$GP"
  out="$(bash "$PC" "$R" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qxF "    bin/x.sh:2:$GP"; } || { echo "FAIL T2: a root holding $q was not checked or not named from the root down (exit $rc): $out"; exit 1; }
done
# T3: a file whose own name holds a space is checked
R="$EVAL_TMP/t3"; mkdir -p "$R/bin" && printf '#!/usr/bin/env bash\nmapfile -t a < f\n' > "$R/bin/my tool.sh"
out="$(bash "$PC" "$R" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "bin/my tool.sh:2:"; } || { echo "FAIL T3: a script whose name holds a space was not checked (exit $rc): $out"; exit 1; }
# T4: the lz and zstd forms of a perl-regex grep are reported, and so is a line that ends in the flag
for c in "lz$G $P x f" "zstd$G $P x f" "$G $P"; do
  R="$EVAL_TMP/t4-$RANDOM"; tree "$R" "$c"
  out="$(bash "$PC" "$R" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "grep-perl"; } || { echo "FAIL T4: '$c' was not reported (exit $rc): $out"; exit 1; }
done
# T5: a clean tree under such a path is clean, and a pragma still silences its rule
R="$EVAL_TMP/c d/root"; tree "$R" 'grep -E "x" file'
bash "$PC" "$R" >/dev/null 2>&1 || { echo "FAIL T5: a clean tree under a path holding a space was not clean"; exit 1; }
tree "$R" "$GP   # portability-ok: grep-perl"
bash "$PC" "$R" >/dev/null 2>&1 || { echo "FAIL T5: the portability-ok pragma no longer silences its rule"; exit 1; }
exit 0
