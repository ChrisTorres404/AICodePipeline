#!/usr/bin/env bash
# lock-trap: with_id_lock keeps the caller's EXIT trap, in bin/wo and bin/bug.
set -uo pipefail
for drv in wo bug; do
  case "$drv" in wo) dirvar=WO_DIR;; bug) dirvar=BUG_DIR;; esac
  sed -n '/^with_id_lock() {/,/^}/p' "$PIPELINE_ROOT/bin/$drv" > "$EVAL_TMP/$drv-lock.sh"
  [ -s "$EVAL_TMP/$drv-lock.sh" ] || { echo "FAIL setup $drv: with_id_lock not found in bin/$drv"; exit 1; }
  for case in keep exit none exitrc exit0 nest; do
    d="$EVAL_TMP/$drv-$case"; mkdir -p "$d"; out="$d/out"; : > "$out"
    {
      echo 'set -euo pipefail'
      echo 'die() { echo "$*" >&2; exit 1; }'
      echo "$dirvar=\"$d/records\""
      echo ". \"$EVAL_TMP/$drv-lock.sh\""
      case "$case" in
        keep) echo "trap 'echo caller-trap-ran >> \"$out\"' EXIT"
              echo 'before="$(trap -p EXIT)"'
              echo 'with_id_lock true'
              echo '[ "$(trap -p EXIT)" = "$before" ] && echo trap-restored >> "'"$out"'"';;
        exit) echo "trap 'echo caller-trap-ran-\$? >> \"$out\"' EXIT"
              echo 'with_id_lock exit 3';;
        none) echo 'with_id_lock true'
              echo '[ -z "$(trap -p EXIT)" ] && echo no-trap-left >> "'"$out"'"';;
        exitrc) echo "trap 'rc=\$?; echo \"caller-saw-\$rc\" >> \"$out\"; exit \$rc # the caller ends with exit' EXIT"
              echo 'with_id_lock exit 3';;
        exit0) echo "trap 'echo caller-trap-ran-\$? >> \"$out\"' EXIT"
              echo 'with_id_lock exit 0';;
        nest) echo "inner() { $dirvar=\"$d/records2\"; with_id_lock exit 5; }"
              echo 'with_id_lock inner';;
      esac
    } > "$d/case.sh"
    bash "$d/case.sh" >/dev/null 2>&1; st=$?
    [ ! -e "$d/records/.acp-id.lock" ] || { echo "FAIL $drv-$case: the lock outlived the section"; exit 1; }
    case "$case" in
      keep) grep -qx trap-restored "$out" || { echo "FAIL $drv-keep: the caller's EXIT trap was lost"; exit 1; }
            grep -qx caller-trap-ran "$out" || { echo "FAIL $drv-keep: the caller's EXIT trap did not run at exit"; exit 1; };;
      exit) grep -qx caller-trap-ran-3 "$out" || { echo "FAIL $drv-exit: the caller's EXIT trap did not run with exit status 3 when the section exited"; exit 1; };;
      none) grep -qx no-trap-left "$out" || { echo "FAIL $drv-none: an EXIT trap was left behind"; exit 1; };;
      exitrc) { grep -qx caller-saw-3 "$out" && [ "$st" -eq 3 ]; } || { echo "FAIL $drv-exitrc: a caller trap ending in exit did not see and keep status 3"; exit 1; };;
      exit0) grep -qx caller-trap-ran-0 "$out" || { echo "FAIL $drv-exit0: the caller's EXIT trap did not run when the section exited 0"; exit 1; };;
      nest) { [ ! -e "$d/records2/.acp-id.lock" ] && [ "$st" -eq 5 ]; } || { echo "FAIL $drv-nest: a nested lock outlived its section"; exit 1; };;
    esac
  done
done
exit 0
