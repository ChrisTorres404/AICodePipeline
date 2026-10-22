#!/usr/bin/env bash
# every-pattern: bin/sanitize tries every pattern on every line and reports one finding per pattern, so a
# warning earlier in the list can no longer hide a critical finding later on the same line.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
S="$PIPELINE_ROOT/bin/sanitize"
# every value is built at run time, so this file holds no key, address or host name
host="build01."; host="${host}internal"; home="/home/"; home="${home}alice/work"
ip="10.1."; ip="${ip}2.3"; key="AKIA""QWERTYUIOPASDFGH"; tok="ghp_"; tok="${tok}$(printf 'a%.0s' $(seq 1 36))"
mkdir -p a b c d e
printf 'deploy from %s into %s\n' "$host" "$home" > a/notes.md
printf 'reach %s then %s\n' "$ip" "$home" > b/notes.md
printf 'keys %s and %s\n' "$key" "$tok" > c/notes.md
printf 'twice %s %s\n' "$key" "$key" > d/notes.md
printf 'only %s here\n' "$host" > e/notes.md
scan() { out="$("$S" "$@" 2>&1)"; rc=$?; }
has() { printf '%s\n' "$out" | grep -cF "**[$1]** \`$2\`" || true; }
# P1: a home path after an internal host name on the same line is found, and the scan FAILs
scan a
{ [ "$rc" -eq 2 ] && [ "$(has path.home notes.md:1)" = 1 ] && [ "$(has infra.hostname notes.md:1)" = 1 ]; } \
  || { echo "FAIL P1: a home path next to an internal host name was not found"; echo "  exit $rc"; exit 1; }
# P2: a home path after a private IP is found too
scan b
{ [ "$rc" -eq 2 ] && [ "$(has path.home notes.md:1)" = 1 ] && [ "$(has infra.privip notes.md:1)" = 1 ]; } \
  || { echo "FAIL P2: a home path next to a private IP was not found"; echo "  exit $rc"; exit 1; }
# P3: two different secrets on one line are two findings
scan c
{ [ "$rc" -eq 2 ] && [ "$(has secret.aws notes.md:1)" = 1 ] && [ "$(has secret.github notes.md:1)" = 1 ]; } \
  || { echo "FAIL P3: two secrets on one line were not both reported"; echo "  exit $rc"; exit 1; }
# P4: one pattern matching twice on a line is one finding, not two
scan d
{ [ "$rc" -eq 2 ] && [ "$(has secret.aws notes.md:1)" = 1 ]; } || { echo "FAIL P4: one pattern on one line was not exactly one finding"; echo "  exit $rc"; exit 1; }
# P5: a line holding only a warning is still a warning
scan e
{ [ "$rc" -eq 1 ] && [ "$(has infra.hostname notes.md:1)" = 1 ]; } || { echo "FAIL P5: a line holding only a host name was not a warning"; echo "  exit $rc"; exit 1; }
exit 0
