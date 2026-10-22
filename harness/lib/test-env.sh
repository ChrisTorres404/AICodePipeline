#!/usr/bin/env bash
# ============================================================================
# Shared environment primitives for the harness
# ============================================================================
# Sourced, never executed. It holds the handful of things every runner and
# every library needed a copy of before: where the service is, whether a
# database is configured, and how to put the system back into a known state
# between batches of suites.
#
#   . "$(dirname "$0")/../lib/test-env.sh"
#
# One copy, because the alternative is what this file replaced: the same
# health_url in three scripts, each drifting on its own. Nothing here assumes a
# particular application — the database, cache and prep blocks are inert until
# the project configures them in config/test-config.env.
#
# Provides:
#   health_url                    the first health endpoint that answers 200
#   db_configured                 true when DB_NAME is set and psql exists
#   run_psql                      one query against a chosen database
#   release_idle_db_connections   terminate idle backends left by a suite
#   recover_db_pool               the same, but only over a threshold, then settle
#   flush_rate_limiter            flush the cache/rate limiter the project names
#   reset_test_environment        REDIS_FLUSH + TEST_PREP_SQL, both optional
#   clean_risk_state              the same, under the name a risk-scoring
#                                 project reaches for — one alias, not a second
#                                 implementation
#   prepare_test_environment      health check, reset, pool check — before a run
#
# Every library in harness/lib sources this file rather than keeping a copy of
# any of it. The pair that made that a rule: verbose-test-framework.sh once had
# its own reset_test_environment which called redis-cli directly and never read
# CACHE_FLUSH_CMD, so a project whose limiter is not Redis had a known-state
# step that silently did nothing.
# ============================================================================

# Guard: several files source this, and a suite may source two of them.
if [ -n "${_HARNESS_TEST_ENV_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_HARNESS_TEST_ENV_LOADED=1

# ----------------------------------------------------------------------------
# Service under test
# ----------------------------------------------------------------------------
# The rendered default lives in a variable: `${API_BASE:-{{...}}}` would
# append the extra braces to an API_BASE that is already set.
_default_api_base='{{API_BASE_URL}}'
API_BASE="${API_BASE:-$_default_api_base}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
METRICS_PATH="${METRICS_PATH:-/metrics}"

# A browser User-Agent by default: services that score clients for risk, or
# block unknown agents outright, treat curl-like agents as suspicious and would
# make the harness measure the bot filter instead of the feature.
TEST_USER_AGENT="${TEST_USER_AGENT:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"

# The health endpoint is usually at the host root (/health), not under the API
# prefix. Try both and use the first that answers 200.
health_url() {
  local host; host="$(printf '%s' "$API_BASE" | sed -E 's|^(https?://[^/]+).*|\1|')"
  local u
  for u in "${API_BASE%/}${HEALTH_PATH}" "${host}${HEALTH_PATH}"; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -A "${TEST_USER_AGENT:-harness}" "$u" 2>/dev/null)" = "200" ] && { printf '%s' "$u"; return 0; }
  done
  printf '%s' "${API_BASE%/}${HEALTH_PATH}"; return 1
}

# ----------------------------------------------------------------------------
# Database
# ----------------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-${USER:-$(id -un 2>/dev/null || true)}}"
DB_NAME="${DB_NAME:-}"
export PGPASSWORD="${PGPASSWORD:-${DB_PASS:-}}"

# The database a maintenance query connects to. Counting and terminating idle
# backends has to work exactly when the pool for DB_NAME is exhausted, so it
# runs against the server's always-present maintenance database instead.
DB_MAINTENANCE_DB="${DB_MAINTENANCE_DB:-postgres}"

# A pool check must never be the thing that hangs a run: give up on a
# connection rather than waiting on an unreachable host.
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-5}"

# Over this many idle backends, recover_db_pool acts; below it, it says nothing.
DB_POOL_IDLE_THRESHOLD="${DB_POOL_IDLE_THRESHOLD:-5}"
# Seconds to let the service rebuild its pool after backends were terminated.
DB_POOL_SETTLE_SECONDS="${DB_POOL_SETTLE_SECONDS:-5}"

db_configured() {
  [ -n "${DB_NAME:-}" ] && command -v psql > /dev/null 2>&1
}

# One query, single-value output, against a named database (default DB_NAME).
#   run_psql "SELECT 1;" "$DB_MAINTENANCE_DB"
run_psql() {
  local query="$1"
  local database="${2:-$DB_NAME}"
  db_configured || return 1
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$database" -t -A -c "$query" 2>/dev/null
}

# How many backends the service has left sitting idle against DB_NAME.
idle_db_connections() {
  local n
  n="$(run_psql "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND state = 'idle';" "$DB_MAINTENANCE_DB" 2>/dev/null || echo 0)"
  n="$(printf '%s' "$n" | tr -d '[:space:]')"
  case "$n" in ''|*[!0-9]*) echo 0;; *) echo "$n";; esac
}

# Terminate the idle backends a suite left behind, so the next suite is not
# blocked by an exhausted pool. No-op when no database is configured.
release_idle_db_connections() {
  db_configured || return 0
  run_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND state = 'idle' AND pid <> pg_backend_pid();" \
    "$DB_MAINTENANCE_DB" > /dev/null 2>&1 || true
}

# The same, but only when the pool is actually congested, and with a settle
# period afterwards. This is what belongs between tiers: a suite that opened
# dozens of sessions leaves the next tier unable to log in at all, and the
# service needs a moment to rebuild its pool before anything is asked of it.
recover_db_pool() {
  db_configured || return 0
  local idle; idle="$(idle_db_connections)"
  if [ "$idle" -gt "$DB_POOL_IDLE_THRESHOLD" ] 2>/dev/null; then
    echo "  pool recovery: $idle idle connections, terminating..."
    release_idle_db_connections
    sleep "$DB_POOL_SETTLE_SECONDS"
    echo "  pool recovered"
    return 0
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Cache / rate limiter
# ----------------------------------------------------------------------------
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Flush whatever the project uses to count requests per client. CACHE_FLUSH_CMD
# overrides the command outright, for a project whose limiter is not Redis.
# Calling this directly flushes; reset_test_environment only does so when
# REDIS_FLUSH=1, because that runs unasked before every batch.
flush_rate_limiter() {
  if [ -n "${CACHE_FLUSH_CMD:-}" ]; then
    eval "$CACHE_FLUSH_CMD" > /dev/null 2>&1 || return 1
    return 0
  fi
  command -v redis-cli > /dev/null 2>&1 || return 1
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" FLUSHDB > /dev/null 2>&1 || return 1
  return 0
}

# ----------------------------------------------------------------------------
# Known state
# ----------------------------------------------------------------------------
# Put the system back into the state a batch of suites expects. Both halves are
# opt-in and both are inert until the project configures them:
#
#   REDIS_FLUSH=1     flush the rate limiter / cache
#   TEST_PREP_SQL     SQL executed against DB_NAME
#
# The SQL is where a project clears whatever its own service holds against a
# test client between batches — accumulated failed-login events that drive an
# adaptive risk score, a lockout counter, a queue. Run it between tiers, not
# once at the start: the state that blocks a login is built by the suites that
# ran before it.
reset_test_environment() {
  local did=0

  if [ "${REDIS_FLUSH:-0}" = "1" ]; then
    if flush_rate_limiter; then
      echo "  rate limiter flushed"
      did=1
    fi
  fi

  if [ -n "${TEST_PREP_SQL:-}" ] && db_configured; then
    if run_psql "$TEST_PREP_SQL" > /dev/null 2>&1; then
      echo "  prep SQL applied"
    else
      echo "  prep SQL failed"
    fi
    did=1
  fi

  [ "$did" -eq 1 ] && return 0
  return 0
}

# The same step, under the name a suite reaches for when what it is clearing is
# the service's opinion of the client: failed-login events feeding an adaptive
# risk score, a lockout counter, a rate-limit window. It is an alias and not a
# second implementation, so CACHE_FLUSH_CMD and TEST_PREP_SQL are honoured
# identically whichever name a suite calls.
#
#   clean_risk_state          # between batches, exactly as reset_test_environment
clean_risk_state() {
  reset_test_environment "$@"
}

# Everything a run should do before it claims anything: prove the service
# answers, reset the state, and check the pool. Returns non-zero when the
# service is not there — a run that continues past that measures nothing.
prepare_test_environment() {
  local url code
  url="$(health_url || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -A "$TEST_USER_AGENT" "$url" 2>/dev/null || true)"; code="${code:-000}"
  if [ "$code" != "200" ]; then
    echo "  service not responding at ${API_BASE%/}${HEALTH_PATH} or the host root (HTTP $code)"
    return 1
  fi
  echo "  service healthy (HTTP $code) at $url"

  reset_test_environment

  if db_configured; then
    local idle; idle="$(idle_db_connections)"
    if [ "$idle" -gt "$DB_POOL_IDLE_THRESHOLD" ] 2>/dev/null; then
      recover_db_pool
    else
      echo "  DB pool healthy ($idle idle connections)"
    fi
  fi
  return 0
}
