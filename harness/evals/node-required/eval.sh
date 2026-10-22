#!/usr/bin/env bash
# node-required: the harness-results-path eval fails, instead of passing, when node is missing.
set -uo pipefail
target="$PIPELINE_ROOT/harness/evals/harness-results-path/eval.sh"
[ -f "$target" ] || { echo "FAIL setup: harness-results-path is missing"; exit 1; }
node_dir="$(dirname "$(command -v node 2>/dev/null || echo /nonexistent/node)")"
[ -x "$node_dir/node" ] || { echo "FAIL setup: node is not on this eval's PATH, so the with-node case cannot run"; exit 1; }
for p in /usr/bin/node /bin/node; do [ -e "$p" ] && { echo "FAIL setup: $p exists, so the without-node case cannot run"; exit 1; }; done
# N1: without node on PATH it must fail, and say why
mkdir -p "$EVAL_TMP/n1"
out="$(env -i USER=acp LOGNAME=acp PATH=/usr/bin:/bin HOME="$EVAL_TMP" PIPELINE_ROOT="$PIPELINE_ROOT" EVAL_TMP="$EVAL_TMP/n1" bash "$target" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL N1: harness-results-path passed without node"; exit 1; }
printf '%s\n' "$out" | grep -qxF "node is not on PATH: the coverage summary check cannot run" \
  || { echo "FAIL N1: harness-results-path failed without node, but not for that reason"; exit 1; }
# N2: with node on PATH it still passes
mkdir -p "$EVAL_TMP/n2"
env -i USER=acp LOGNAME=acp PATH="$node_dir:/usr/bin:/bin" HOME="$EVAL_TMP" PIPELINE_ROOT="$PIPELINE_ROOT" EVAL_TMP="$EVAL_TMP/n2" bash "$target" >/dev/null 2>&1 \
  || { echo "FAIL N2: harness-results-path fails even with node on PATH"; exit 1; }
exit 0
