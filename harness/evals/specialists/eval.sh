#!/usr/bin/env bash
# specialists: resolve_specialists puts the stack's specialist names in as data. A name that is not an
# agent name (lower-case letters, digits, -) falls back to the default; a plain one is used as it is.
set -uo pipefail
cd "$EVAL_TMP" || exit 1
"$PIPELINE_ROOT/bin/new-project" p --name P --no-git >/dev/null 2>&1 || { echo "FAIL setup: new-project failed"; exit 1; }
cd p || exit 1
B=.aicodepipeline/bin; W="$B/wo"; n=0
[ -x "$W" ] && [ -f "$B/stack-specialist" ] || { echo "FAIL setup: the installed copy has no wo or stack-specialist"; exit 1; }
# a stack-specialist that prints whatever the test puts in $B/ss-<kind>
printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/ss-$1"\n' > "$B/stack-specialist"; chmod +x "$B/stack-specialist"
put() { printf '%s\n' "$1" > "$B/ss-backend"; printf '%s\n' "$2" > "$B/ss-ui"; printf '%s\n' "$3" > "$B/ss-data"; }
routed() { # <area>...: open a work order for each area; v = each one's primary, backup and validator, joined by " / "
  local a; v=""
  for a in "$@"; do
    n=$((n+1)); $W new "r$n" --area "$a" >/dev/null 2>&1
    m="$(ls -d Workspace/Docs/WorkOrders/WO-*-r$n 2>/dev/null | head -1)/.wo-meta"
    v="$v${v:+ / }$(sed -n 's/^primary=//p' "$m" 2>/dev/null) $(sed -n 's/^backup=//p' "$m" 2>/dev/null) $(sed -n 's/^validator=//p' "$m" 2>/dev/null)"
  done; }
# S1: a name holding & is not pasted into the routing as sed text
put 'x&y' 'u&v' 'd&e'
routed backend frontend database; [ "$v" = "rest-expert architect project-validator-expert / react-expert ux-ui-designer-expert frontend-validator-expert / postgres-expert rest-expert database-validator-expert" ] || { echo "FAIL S1: a specialist name holding & went into the routing as sed text"; echo "  routed: $v"; exit 1; }
# S1b: a name with capitals, or a letter outside a-z, falls back too, in any locale
put Django-Expert 'vué-expert' 'ｐostgres-expert'
LC_ALL=en_US.UTF-8 routed backend frontend database; [ "$v" = "rest-expert architect project-validator-expert / react-expert ux-ui-designer-expert frontend-validator-expert / postgres-expert rest-expert database-validator-expert" ] || { echo "FAIL S1: a specialist name that is not lower-case a-z was used: $v"; exit 1; }
# S2: a name holding / does not blank the routing
put 'a/b' 'c/d' 'e/f'
routed backend frontend database; [ "$v" = "rest-expert architect project-validator-expert / react-expert ux-ui-designer-expert frontend-validator-expert / postgres-expert rest-expert database-validator-expert" ] || { echo "FAIL S2: a specialist name holding / broke the routing: $v"; exit 1; }
# S3: a name holding | does not shift the backup and validator
put 'a|b' 'c|d' 'e|f'
routed backend frontend database; [ "$v" = "rest-expert architect project-validator-expert / react-expert ux-ui-designer-expert frontend-validator-expert / postgres-expert rest-expert database-validator-expert" ] || { echo "FAIL S3: a specialist name holding | shifted the routing: $v"; exit 1; }
# S4: an empty name falls back too, each kind to its own default
put '' '' ''
routed backend frontend database
[ "$v" = "rest-expert architect project-validator-expert / react-expert ux-ui-designer-expert frontend-validator-expert / postgres-expert rest-expert database-validator-expert" ] \
  || { echo "FAIL S4: an empty specialist name was used: $v"; exit 1; }
# S5: plain names are used as they are, in every place a token stands, by wo new and wo route
put django-expert vue-expert typeorm-expert
routed backend frontend database performance
[ "$v" = "django-expert architect project-validator-expert / vue-expert ux-ui-designer-expert frontend-validator-expert / typeorm-expert django-expert database-validator-expert / performance-optimizer django-expert project-validator-expert" ] \
  || { echo "FAIL S5: plain specialist names were not used as they are: $v"; exit 1; }
$W route database 2>/dev/null | grep -E '^  implement +typeorm-expert ' >/dev/null || { echo "FAIL S5: wo route did not show the plain name"; exit 1; }
# S6: a name holding a newline adds no line to the work order's metadata
put 'x
primary=evil' 'u
primary=evil' 'd
primary=evil'
routed frontend backend database; [ "$v" = "react-expert ux-ui-designer-expert frontend-validator-expert / rest-expert architect project-validator-expert / postgres-expert rest-expert database-validator-expert" ] \
  && [ "$(grep -c '^primary=' Workspace/Docs/WorkOrders/WO-*-r$((n-2))/.wo-meta)" = 1 ] && [ "$(grep -c '^primary=' Workspace/Docs/WorkOrders/WO-*-r$((n-1))/.wo-meta)" = 1 ] && [ "$(grep -c '^primary=' "$m")" = 1 ] \
  || { echo "FAIL S6: a specialist name holding a newline reached the metadata: $(grep -E '^(primary|backup)=' "$m" | tr '\n' ' ')"; exit 1; }
exit 0
