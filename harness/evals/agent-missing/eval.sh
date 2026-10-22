#!/usr/bin/env bash
# agent-missing: a routed specialist with no installed definition is named as such; wo new and wo route
# finish instead of stopping without a word.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
B=.aicodepipeline/bin; W="$B/wo"
[ -x "$W" ] && [ -f "$B/stack-specialist" ] || { echo "FAIL setup: the installed copy has no wo or stack-specialist"; exit 1; }
printf '#!/usr/bin/env bash\necho zz-expert\n' > "$B/stack-specialist"; chmod +x "$B/stack-specialist"
# A1: wo new --area finishes for a specialist with no installed definition
$W new "alpha" --area backend >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL A1: wo new stopped for a specialist with no installed definition (exit $rc)"; exit 1; }
# A2: its work order names that role as having no definition, and still names the next two roles
d="$(ls -d Workspace/Docs/WorkOrders/WO-*-alpha | head -1)"
grep -rqF -- '- **implement:** `zz-expert` — no definition installed for this name' "$d" \
  && grep -rqF -- '- **backup:** `architect` — ' "$d" && grep -rqF -- '- **validate:** `project-validator-expert` — ' "$d" \
  || { echo "FAIL A2: the work order does not name each routed specialist, or say which has no definition"; exit 1; }
# A3: wo route finishes too, showing no definition for that one and the path for an installed one
out="$($W route backend 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^  implement +zz-expert *$' \
  && printf '%s\n' "$out" | grep -qE '^  backup +architect +[^ ]*architect\.md$'; } \
  || { echo "FAIL A3: wo route stopped or misreported for a specialist with no installed definition (exit $rc): $out"; exit 1; }
exit 0
