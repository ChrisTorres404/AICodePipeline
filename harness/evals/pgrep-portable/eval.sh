#!/usr/bin/env bash
# pgrep-portable: the portability check's grep-perl rule flags grep with the perl flag, not pgrep -P.
set -uo pipefail
PC="$PIPELINE_ROOT/bin/maintenance/portability-check.sh"
F='-'P; G='-o'P; L='--perl'-regexp   # the flags under test, assembled so this file does not itself trip the rule it tests
case_root() { # <name> <one line of shell>: a scratch tree holding one script with that line
  mkdir -p "$EVAL_TMP/$1"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$EVAL_TMP/$1/s.sh"; }
check() { out="$(bash "$PC" "$EVAL_TMP/$1" 2>&1)"; rc=$?; }
# P1: pgrep with -P (parent pid) is portable and is not reported
case_root p1 "pgrep $F \"\$\$\" sleep"
check p1; [ "$rc" -eq 0 ] || { echo "FAIL P1: pgrep -P was reported as grep with the perl flag"; exit 1; }
# P2: grep (or zgrep, bzgrep, xzgrep) with the perl flag is still reported: at the start of a line, after a pipe, a path, ; or a backtick, with other flags
n=0
for line in "grep $F 'a\\d' f" "cat f | grep $F x" "/usr/bin/grep $F x f" "grep -n $G x f" "x=\$(grep $F y f)" "grep $L x f" "true;grep $F x f" "x=\`grep $F y f\`" "zgrep $F x f" "bzgrep $F x f" "xzgrep $F x f"; do
  n=$((n+1)); case_root "p2-$n" "$line"; check "p2-$n"
  { [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qF "grep-perl"; } || { echo "FAIL P2: the perl flag was not reported in: $line"; exit 1; }
done
# P3: other words ending in grep, with -P, are not reported either
case_root p3 "mygrep $F y; my_grep $F z; x.grep $F w; x-grep $F v; my2grep $F u"
check p3; [ "$rc" -eq 0 ] || { echo "FAIL P3: a word ending in grep with -P was reported"; exit 1; }
exit 0
