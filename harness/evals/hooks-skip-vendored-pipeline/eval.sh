#!/usr/bin/env bash
set -uo pipefail
cd "$EVAL_TMP" || exit 1

# An installed project: the pipeline vendored at .aicodepipeline, agents and skills
# copied under .claude. Only the hooks and bin/sanitize (which holds the key list) are copied —
# the hooks derive their own root from where they sit, so the rest of the tree is stand-in files.
mkdir -p proj/.aicodepipeline/core proj/.aicodepipeline/bin proj/.claude/skills/demo/scripts proj/src
cp -R "$PIPELINE_ROOT/core/hooks" proj/.aicodepipeline/core/hooks && cp "$PIPELINE_ROOT/bin/sanitize" proj/.aicodepipeline/bin/ \
  || { echo "could not vendor the hooks"; exit 1; }
mkdir -p proj/.aicodepipeline/core/skills/demo/scripts
cd proj || exit 1
git init -q >/dev/null 2>&1; git config user.email e@x; git config user.name e
printf 'console.log("shipped by the pipeline");\n' > .aicodepipeline/core/skills/demo/scripts/build.js
printf 'console.log("installed skill copy");\n'   > .claude/skills/demo/scripts/build.js

CQ=.aicodepipeline/core/hooks/commit-quality.py
QG=.aicodepipeline/core/hooks/quality-gate.py
CK=.aicodepipeline/core/hooks/check.py
commit_hook() { printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | ACP_STRICT=1 python3 "$CQ" 2>&1; }
edit_hook() { # <path>
  python3 -c "import json,sys; print(json.dumps({'tool_input':{'file_path':sys.argv[1],'content':open(sys.argv[1]).read()}}))" "$1" \
    | ACP_STRICT=1 python3 "$QG" 2>&1; }

# --- the first commit after an install: everything staged is the pipeline's own ---
git add -A >/dev/null 2>&1
out="$(commit_hook)"; rc=$?
[ "$rc" -eq 0 ] || { echo "the first commit after an install was blocked by the pipeline's own source (exit $rc)"; echo "$out"; exit 1; }

# --- the project's own code is still reported ---
printf 'console.log("mine");\n' > src/app.js; git add -A >/dev/null 2>&1
out="$(commit_hook)"; rc=$?
{ [ "$rc" -eq 2 ] && case "$out" in *"Debug logging"*) true;; *) false;; esac; } || { echo "debug logging in the project's own source was not reported under strict (exit $rc)"; echo "$out"; exit 1; }
case "$out" in *"src/app.js"*) ;; *) echo "the report did not name the project's file:"; echo "$out"; exit 1;; esac
case "$out" in *.aicodepipeline*) echo "the report named the vendored pipeline:"; echo "$out"; exit 1;; *) ;; esac
case "$out" in *.claude*) echo "the report named the installed .claude copies:"; echo "$out"; exit 1;; *) ;; esac

# --- the edit hook draws the same line ---
rc=0; edit_hook .aicodepipeline/core/skills/demo/scripts/build.js >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { echo "editing a file inside the vendored pipeline was blocked under strict (exit $rc)"; exit 1; }
rc=0; edit_hook .claude/skills/demo/scripts/build.js >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || { echo "editing an installed skill copy under .claude was blocked under strict (exit $rc)"; exit 1; }
rc=0; edit_hook src/app.js >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "debug logging written into the project's own source was not reported under strict (exit $rc)"; exit 1; }

# --- check draws the same line, invoked directly, with no --exclude from acp ---
out="$(python3 "$CK" --root . --strict --paths .aicodepipeline/core/skills/demo/scripts/build.js .claude/skills/demo/scripts/build.js 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || { echo "check reported the vendored pipeline the hooks skip (exit $rc)"; echo "$out"; exit 1; }
out="$(python3 "$CK" --root . --strict --paths src/app.js 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || { echo "check did not report the project's own debug logging under strict (exit $rc)"; echo "$out"; exit 1; }

# --- a checkout of the pipeline is itself a project: the rules still run there ---
cd "$EVAL_TMP" || exit 1
mkdir -p self/core self/bin src
cp -R "$PIPELINE_ROOT/core/hooks" self/core/hooks && cp "$PIPELINE_ROOT/bin/sanitize" self/bin/
cd self || exit 1
git init -q >/dev/null 2>&1; git config user.email e@x; git config user.name e
mkdir -p core/skills; printf 'console.log("the pipeline own source");\n' > core/skills/build.js
git add -A >/dev/null 2>&1
out="$(printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | ACP_STRICT=1 python3 core/hooks/commit-quality.py 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || { echo "the rules switched themselves off in a checkout of the pipeline itself (exit $rc)"; echo "$out"; exit 1; }
exit 0
