#!/usr/bin/env bash
# user-unset: harness/config/test-config.env works when USER is unset (CI, cron, env -i).
set -uo pipefail
cfg="$PIPELINE_ROOT/harness/config/test-config.env"
[ -f "$cfg" ] || { echo "FAIL setup: no harness/config/test-config.env"; exit 1; }
me="$(id -un)"
[ -n "$me" ] || { echo "FAIL setup: id -un printed nothing"; exit 1; }
for envname in LOCAL_DEV LOCAL_TEST DOCKER; do
  got="$(env -i PATH=/usr/bin:/bin HOME="$EVAL_TMP" ACTIVE_ENV="$envname" bash -c 'set -u; . "$1" >/dev/null && printf "%s" "$DB_USER"' _ "$cfg" 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL $envname: sourcing test-config.env failed with USER unset"; exit 1; }
  [ "$got" = "$me" ] || { echo "FAIL $envname: DB_USER with USER unset is '$got', expected the login name"; exit 1; }
  got="$(env -i PATH=/usr/bin:/bin HOME="$EVAL_TMP" USER=acp238_probe ACTIVE_ENV="$envname" bash -c 'set -u; . "$1" >/dev/null && printf "%s" "$DB_USER"' _ "$cfg" 2>&1)"
  [ "$got" = acp238_probe ] || { echo "FAIL $envname: DB_USER no longer follows USER (got '$got')"; exit 1; }
  got="$(env -i PATH=/usr/bin:/bin HOME="$EVAL_TMP" USER=acp238_probe DB_USER=dbx ACTIVE_ENV="$envname" bash -c 'set -u; . "$1" >/dev/null && printf "%s" "$DB_USER"' _ "$cfg" 2>&1)"
  [ "$got" = dbx ] || { echo "FAIL $envname: an exported DB_USER no longer wins (got '$got')"; exit 1; }
done
exit 0
