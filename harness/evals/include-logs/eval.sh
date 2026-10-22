#!/usr/bin/env bash
# include-logs: bin/sanitize scans .log files when asked (--include-logs), and only then: a default scan is
# exactly as before, so playbooks that already hold logs do not start failing.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
S="$PIPELINE_ROOT/bin/sanitize"
key="AKIA""QWERTYUIOPASDFGH"   # built at run time, so this file holds no key
mkdir -p a b c d e
printf 'run started\nexported %s for the deploy\n' "$key" > a/run.log
printf 'run started\nall checks passed\n' > b/run.log
printf 'notes: %s\n' "$key" > c/notes.md
printf 'bin\000ary %s\n' "$key" > d/blob.log
printf 'exported %s\n' "$key" > e/RUN.LOG
scan() { out="$("$S" "$@" 2>&1)"; rc=$?; }
# L1: with --include-logs, a secret in a .log file is a FAIL that names the file
scan a --include-logs
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'run.log:2'; } || { echo "FAIL L1: sanitize --include-logs did not find a secret in a .log file"; echo "  exit $rc"; exit 1; }
# L2: without it, the same folder scans as before: the .log file is not read, and the result is PASS
scan a
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF '**Files scanned:** 0'; } || { echo "FAIL L2: a default scan read a .log file"; echo "  exit $rc"; exit 1; }
# L3: a clean .log file is scanned and passes
scan b --include-logs
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF '**Files scanned:** 1'; } || { echo "FAIL L3: sanitize --include-logs did not scan a clean .log file"; echo "  exit $rc"; exit 1; }
# L4: other files are scanned the same either way
scan c; r1=$rc; scan c --include-logs; r2=$rc
{ [ "$r1" -eq 2 ] && [ "$r2" -eq 2 ]; } || { echo "FAIL L4: --include-logs changed the scan of a file that is not a log"; echo "  exit $r1 then $r2"; exit 1; }
# L5: a .log file holding binary data is still skipped
scan d --include-logs
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF '**Files scanned:** 0'; } || { echo "FAIL L5: sanitize --include-logs read a binary .log file"; echo "  exit $rc"; exit 1; }
# L6: several folders at once, with the flag after them, as new-project and promote may call it
scan a b --include-logs
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'a/run.log:2'; } || { echo "FAIL L6: sanitize --include-logs over two folders did not find the secret"; echo "  exit $rc"; exit 1; }
# L7: the extension is read in any case: a secret in RUN.LOG is found too
scan e --include-logs
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -qF 'RUN.LOG:1'; } || { echo "FAIL L7: sanitize --include-logs did not read a .LOG file"; echo "  exit $rc"; exit 1; }
exit 0
