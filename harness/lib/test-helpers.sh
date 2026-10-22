#!/bin/bash
# ============================================================================
# Shared Test Helpers
# ============================================================================
# Source this from a behavioral suite, after the configuration:
#
#   ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
#   source "$ROOT/{{PIPELINE_ROOT}}/harness/config/test-config.env"
#   source "$ROOT/{{PIPELINE_ROOT}}/harness/lib/test-helpers.sh"
#   (or start from core/templates/testing/SUITE-TEMPLATE.sh: `wo suite <n>` scaffolds it)
#
# Nothing here assumes a particular application. HTTP helpers need only
# API_BASE; SQL helpers are inert unless DB_NAME is set; the auth helpers are
# driven entirely by the AUTH_*, CSRF_* and *_COOKIE variables in
# test-config.env and are only needed by suites that authenticate. No path,
# header name, cookie name or body field is written into this file: every one
# of them is a configured default, so a project whose login lives at
# /session and whose CSRF header is X-XSRF-TOKEN changes two variables rather
# than forking the harness.
#
# Sections:
#   output            test_start, test_pass/fail/skip, print_summary
#   counters          every assertion here feeds one set of counters
#   database          run_sql_formatted, assert_sql_contains, extract_id
#   HTTP              auth_get, auth_post, auth_put/patch/delete
#   authentication    get_csrf_token, register_user, login_user, refresh_token, logout
#   accounts          lockout helpers
#   parsing           get_http_code, get_response_body, get_json_field
#   assertions        assert_http_code, assert_contains, assert_not_empty, assert_gte
#
# Sourced, not defined here (one definition each, in harness/lib):
#   test-common.sh    section_header, http_get/http_post and the other verbs,
#                     run_sql, auth_body, random_email, create_test_user,
#                     delete_test_user, assert_http_status, assert_json_equals,
#                     assert_sql_equals
#   test-env.sh       health_url, db_configured, run_psql, flush_rate_limiter,
#                     reset_test_environment and its alias clean_risk_state
#
# Two things a suite should know:
#   - a session captured inside `RESPONSE="$(login_user ...)"` is captured in a
#     subshell; call load_session afterwards, or use the request helpers, which
#     restore it for themselves.
#   - if the suite installs its own EXIT trap, call cleanup_test_tmp from it.
# ============================================================================

# The shared definitions — one copy, shared with test-framework.sh and
# verbose-test-framework.sh. It sources test-env.sh in turn, so the service,
# database, cache and known-state primitives arrive with it.
# shellcheck source=./test-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/test-common.sh"

# ====================================================================
# Session state
# ====================================================================
# Initialised here so a suite running under `set -u` can read them before
# anything has logged in.
CURRENT_ACCESS_TOKEN="${CURRENT_ACCESS_TOKEN:-}"
CURRENT_REFRESH_TOKEN="${CURRENT_REFRESH_TOKEN:-}"
CURRENT_CSRF_TOKEN="${CURRENT_CSRF_TOKEN:-}"
CURRENT_USER_ID="${CURRENT_USER_ID:-}"

# Scratch space for request bodies. Written to files rather than passed on the
# command line: a password containing ! or $ is mangled by the shell long
# before curl sees it, and the test then measures the mangling.
tmpbase="${TMPDIR:-/tmp}"; TEST_TMP_DIR="${TEST_TMP_DIR:-${tmpbase%/}/harness-suite.$$}"
COOKIE_JAR="${COOKIE_JAR:-$TEST_TMP_DIR/cookies.txt}"

# Created on first use, not at source time: sourcing a library should not
# leave anything on disk.
_tmp_dir() {
  [ -d "$TEST_TMP_DIR" ] || mkdir -p "$TEST_TMP_DIR" 2>/dev/null
  printf '%s' "$TEST_TMP_DIR"
}

# The cookie jar, with its directory guaranteed to exist. A project that set
# COOKIE_JAR to somewhere of its own is honoured — which is the point of having
# the variable at all.
_cookie_jar() {
  local dir; dir="$(dirname "$COOKIE_JAR")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
  printf '%s' "$COOKIE_JAR"
}

cleanup_test_tmp() {
  [ -n "${TEST_TMP_DIR:-}" ] || return 0
  rm -rf "$TEST_TMP_DIR" 2>/dev/null || true
}

# Only when the suite has not claimed EXIT for itself — a suite that starts the
# service under test needs its own trap to stop it again, and a library must
# not take that away from it. Such a suite should call cleanup_test_tmp from
# its own handler; the sweep below is the backstop for the ones that forget,
# so a session file cannot sit in the temp directory indefinitely.
if [ -z "$(trap -p EXIT 2>/dev/null)" ]; then
  trap cleanup_test_tmp EXIT
fi
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'harness-suite.*' -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true

# The marker curl writes after a body so the status code survives being piped
# around with it. get_http_code and get_response_body split them apart again.
HTTP_STATUS_MARKER="---HTTP_STATUS:"

# ====================================================================
# Colours
# ====================================================================
# Defaults only: a suite or framework that already set them keeps its own.
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

# ====================================================================
# Counters
# ====================================================================
# One set, fed by every assertion in this file, so print_summary reports what
# actually happened rather than what the last assertion happened to be.
PASSED="${PASSED:-0}"
FAILED="${FAILED:-0}"
SKIPPED="${SKIPPED:-0}"
TOTAL="${TOTAL:-0}"

record_pass() { PASSED=$((PASSED + 1)); }
record_fail() { FAILED=$((FAILED + 1)); }
record_skip() { SKIPPED=$((SKIPPED + 1)); }

# ====================================================================
# Output
# ====================================================================

# section_header comes from test-common.sh.

# Begin a numbered test. TOTAL counts tests started, which is what makes an
# abandoned test visible in the summary instead of silently absent.
test_start() {
  TOTAL=$((TOTAL + 1))
  echo ""
  echo -e "${BLUE}TEST $TOTAL:${NC} ${BOLD}$1${NC}"
}

# Evidence lines: what was requested, what was asked of the database, and what
# came back. A check whose request is not printed cannot be reproduced.
show_http() { echo -e "${DIM}HTTP: $1 $2${NC}"; }
show_sql()  { echo -e "${DIM}SQL: $1${NC}"; }

show_result() {
  local lines
  echo -e "${YELLOW}RAW OUTPUT:${NC}"
  echo "$1" | head -"${SHOW_RESULT_LINES:-20}"
  lines=$(echo "$1" | wc -l | tr -d '[:space:]')
  if [ "${lines:-0}" -gt "${SHOW_RESULT_LINES:-20}" ]; then
    echo -e "${DIM}... (truncated, $lines total lines)${NC}"
  fi
}

test_pass() {
  echo -e "${GREEN}  RESULT: $1${NC}"
  echo -e "${GREEN}  STATUS: PASS${NC}"
  record_pass
}

test_fail() {
  echo -e "${RED}  RESULT: $1${NC}"
  echo -e "${RED}  STATUS: FAIL${NC}"
  record_fail
}

test_skip() {
  echo -e "${YELLOW}  RESULT: $1${NC}"
  echo -e "${YELLOW}  STATUS: SKIP${NC}"
  record_skip
}

# The suite's verdict. Call it last, and let its return value be the suite's
# exit code, or `wo verify --run` records a pass for a run that failed.
#
# Tests and checks are counted separately because they are different numbers:
# test_start counts behaviours under examination, each of which may assert
# several things. Reporting one as the other is how a suite ends up claiming
# more passes than it has tests.
#
# The last line is written in the shape the drivers read counts from
# ("N passed, M failed"), so a work order's verification record carries the
# real ratio rather than just pass or fail.
print_summary() {
  local test_name="${1:-Test}"
  local checks=$(( PASSED + FAILED + SKIPPED ))
  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "  ${test_name} SUMMARY"
  echo "════════════════════════════════════════════════════════════════════"
  printf "  %-20s %s\n" "Tests:" "$TOTAL"
  printf "  %-20s %s\n" "Checks:" "$checks"
  printf "  %-20s %s\n" "Passed:" "$PASSED"
  printf "  %-20s %s\n" "Failed:" "$FAILED"
  printf "  %-20s %s\n" "Skipped:" "$SKIPPED"
  echo "════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Completed: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
  [ "${FAILED:-0}" -eq 0 ]
}

# ====================================================================
# SQL Test Helpers  (no-ops when no database is configured)
# ====================================================================

# run_sql comes from test-common.sh: the result unadorned on stdout, one value
# per line, with SQL_RESULT and SQL_ROW_COUNT set for a caller that ran the
# query for its side effect.

# The same query with psql's own table formatting — for evidence in a report,
# where the column headers are the point.
run_sql_formatted() {
  local query="$1"

  db_configured || { echo "run_sql_formatted: no database configured (set DB_NAME)" >&2; return 1; }

  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$query" 2>/dev/null
}

# Execute SQL and check that the result contains a pattern.
assert_sql_contains() {
  local test_name="$1"
  local query="$2"
  local expected_pattern="$3"

  echo "SQL Test: $test_name"

  local result
  result=$(run_sql "$query" 2>&1)

  if echo "$result" | grep -q "$expected_pattern"; then
    echo "  PASS"
    record_pass
    return 0
  else
    echo "  FAIL (expected: $expected_pattern)"
    echo "  Got: $result"
    record_fail
    return 1
  fi
}

# Pull an identifier out of psql output. Integer keys first, then UUIDs, so one
# helper serves a project on either — or on both at once, which is the usual
# state of a system part-way through a key migration.
extract_id() {
  local int_id
  int_id=$(echo "$1" | grep -oE '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d '[:space:]' | head -1)
  if [ -n "$int_id" ]; then
    echo "$int_id"
    return 0
  fi
  echo "$1" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
}

# Kept for suites written when identifiers were always UUIDs.
extract_uuid() {
  extract_id "$1"
}

# ====================================================================
# HTTP Test Helpers
# ====================================================================

# assert_http_status comes from test-common.sh, which kept this file's call
# shape — assert_http_status "name" URL EXPECTED [METHOD] [JSON_BODY] — and
# also answers the verbose framework's shorter one, assert_http_status 200.

# Extract a JSON field from a response body.
# Usage: extract_json_field "$body" "user.id"
extract_json_field() {
  local response="$1"
  local field="$2"

  echo "$response" | jq -r ".$field"
}

# --- the request the authenticated helpers build -----------------------------
# Header and cookie names are configured, never written in. The bearer header
# defaults to Authorization: Bearer, the CSRF header to X-CSRF-Token, and the
# CSRF cookie to csrf-token; a project sets AUTH_BEARER_HEADER,
# AUTH_BEARER_SCHEME, CSRF_HEADER and CSRF_COOKIE to its own names.
_auth_headers() {
  local access="$1" csrf="$2"
  AUTH_ARGS=(-A "$TEST_USER_AGENT" -H "Content-Type: application/json")
  [ -n "${ORIGIN:-}" ] && AUTH_ARGS+=(-H "Origin: $ORIGIN")
  if [ -n "$access" ]; then
    AUTH_ARGS+=(-H "${AUTH_BEARER_HEADER:-Authorization}: ${AUTH_BEARER_SCHEME:-Bearer} $access")
  fi
  if [ -n "$csrf" ]; then
    AUTH_ARGS+=(-H "${CSRF_HEADER:-X-CSRF-Token}: $csrf")
    AUTH_ARGS+=(-b "${CSRF_COOKIE:-csrf-token}=$csrf")
  fi
}

# Authenticated GET.
# Usage: auth_get "/endpoint" ["access_token"]
auth_get() {
  local endpoint="$1"
  _load_session_if_empty
  local access="${2-$CURRENT_ACCESS_TOKEN}"

  _auth_headers "$access" ""
  curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X GET "${API_BASE}${endpoint}" \
    "${AUTH_ARGS[@]}" 2>/dev/null
}

# Authenticated POST with a JSON body.
# Usage: auth_post "/endpoint" '{"key":"value"}' ["access_token"] ["csrf_token"]
# Passing an explicit empty token means "send none" — the ${x-default} form,
# not ${x:-default}, so a suite can prove an endpoint refuses an anonymous
# caller without having to clear the session first.
auth_post() {
  local endpoint="$1"
  local json_body="$2"
  _load_session_if_empty
  local access="${3-$CURRENT_ACCESS_TOKEN}"
  local csrf="${4-$CURRENT_CSRF_TOKEN}"

  _auth_post_like POST "$endpoint" "$json_body" "$access" "$csrf"
}

# The same for the other mutating verbs, which need the identical CSRF and
# bearer treatment and would otherwise be copied three more times.
auth_put()    { _load_session_if_empty; _auth_post_like PUT    "$1" "$2" "${3-$CURRENT_ACCESS_TOKEN}" "${4-$CURRENT_CSRF_TOKEN}"; }
auth_patch()  { _load_session_if_empty; _auth_post_like PATCH  "$1" "$2" "${3-$CURRENT_ACCESS_TOKEN}" "${4-$CURRENT_CSRF_TOKEN}"; }
auth_delete() { _load_session_if_empty; _auth_post_like DELETE "$1" "${2:-}" "${3-$CURRENT_ACCESS_TOKEN}" "${4-$CURRENT_CSRF_TOKEN}"; }

_auth_post_like() {
  local method="$1" endpoint="$2" json_body="$3" access="$4" csrf="$5"
  local json_file response

  _auth_headers "$access" "$csrf"
  if [ -n "$json_body" ]; then
    json_file="$(_tmp_dir)/body.$$.json"
    printf '%s' "$json_body" > "$json_file"
    AUTH_ARGS+=(-d "@$json_file")
  fi

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X "$method" "${API_BASE}${endpoint}" \
    "${AUTH_ARGS[@]}" 2>/dev/null)

  [ -n "${json_file:-}" ] && rm -f "$json_file"
  echo "$response"
}

# ====================================================================
# Wait/Timing Helpers
# ====================================================================

# Wait for the service under test to answer.
wait_for_server() {
  local url="${1:-$(health_url || true)}"
  local max_wait="${2:-30}"

  echo "Waiting for server at $url..."

  local i
  for i in $(seq 1 "$max_wait"); do
    if curl -s -A "$TEST_USER_AGENT" "$url" > /dev/null 2>&1; then
      echo "  Server ready"
      return 0
    fi
    echo "  Waiting... ($i/$max_wait)"
    sleep 1
  done

  echo "  Server not ready after ${max_wait}s"
  return 1
}

# ====================================================================
# Authentication Helpers  (optional — only for suites that log in)
# ====================================================================

# auth_body comes from test-common.sh, in this file's three-argument form: the
# extra fields are the third argument, or AUTH_EXTRA_LOGIN_FIELDS when it is
# left off.

# Log in and echo the token. Returns non-zero if no token came back.
# Usage: TOKEN=$(auth_login "$email" "$password")
auth_login() {
  local email="$1"
  local password="$2"

  local body response token
  body="$(auth_body "$email" "$password")"
  response=$(curl -s -X POST "${API_BASE}${AUTH_LOGIN_PATH:-/auth/login}" \
    -H "Content-Type: application/json" \
    ${ORIGIN:+-H "Origin: $ORIGIN"} \
    -A "$TEST_USER_AGENT" \
    -d "$body")

  token=$(echo "$response" | jq -r "${AUTH_TOKEN_JQ:-.access_token} // empty" 2>/dev/null)
  if [ -z "$token" ]; then
    echo "auth_login: no token at '${AUTH_TOKEN_JQ:-.access_token}' in login response" >&2
    return 1
  fi
  echo "$token"
}

# --- the session-carrying forms ---------------------------------------------
# auth_login answers one question — "does this credential work" — and is the
# right shape for a suite that only needs a token. The four below carry a whole
# session instead: they set CURRENT_ACCESS_TOKEN, CURRENT_REFRESH_TOKEN,
# CURRENT_CSRF_TOKEN and CURRENT_USER_ID, so a suite can register, act, rotate
# its token and log out without threading four values through every call. Each
# echoes the full response with the status marker appended, for assert_http_code.

# Pull the session out of a login/register/refresh response body.
#
# It is also written to a file, because of how these helpers get called. A
# suite that writes
#
#   RESPONSE="$(login_user "$e" "$p")"
#
# runs login_user in a subshell, and every variable it sets dies with that
# subshell — the login succeeds and the suite is left with no token, which
# looks exactly like an authentication bug in the service. The state file is
# how the session gets back out. load_session restores it into the current
# shell, and the request helpers below do that for themselves, so the token
# is there whichever way the suite was written.
_capture_session() {
  local body="$1" v

  v=$(echo "$body" | jq -r "${AUTH_TOKEN_JQ:-.access_token} // empty" 2>/dev/null)
  [ -n "$v" ] && CURRENT_ACCESS_TOKEN="$v"
  v=$(echo "$body" | jq -r "${AUTH_REFRESH_TOKEN_JQ:-.refresh_token} // empty" 2>/dev/null)
  [ -n "$v" ] && CURRENT_REFRESH_TOKEN="$v"
  v=$(echo "$body" | jq -r "${AUTH_CSRF_TOKEN_JQ:-.csrf_token} // empty" 2>/dev/null)
  [ -n "$v" ] && CURRENT_CSRF_TOKEN="$v"
  v=$(echo "$body" | jq -r "${AUTH_USER_ID_JQ:-.user.id} // empty" 2>/dev/null)
  [ -n "$v" ] && CURRENT_USER_ID="$v"
  _save_session
  return 0
}

# Four lines, fixed order: access, refresh, csrf, user id. A token can be any
# length but never contains a newline, so line-per-value needs no quoting.
_save_session() {
  {
    printf '%s\n' "${CURRENT_ACCESS_TOKEN:-}"
    printf '%s\n' "${CURRENT_REFRESH_TOKEN:-}"
    printf '%s\n' "${CURRENT_CSRF_TOKEN:-}"
    printf '%s\n' "${CURRENT_USER_ID:-}"
  } > "$(_tmp_dir)/session.state" 2>/dev/null || true
}

# Restore the session the last login/register/refresh captured. Call it after
# capturing a response in a command substitution:
#   RESPONSE="$(login_user "$e" "$p")"; load_session
load_session() {
  local f="$TEST_TMP_DIR/session.state"
  [ -f "$f" ] || return 1
  CURRENT_ACCESS_TOKEN="$(sed -n '1p' "$f")"
  CURRENT_REFRESH_TOKEN="$(sed -n '2p' "$f")"
  CURRENT_CSRF_TOKEN="$(sed -n '3p' "$f")"
  CURRENT_USER_ID="$(sed -n '4p' "$f")"
  return 0
}

# What the request helpers call: restore only when this shell has nothing, so a
# suite that set a token by hand keeps it.
_load_session_if_empty() {
  case "${CURRENT_ACCESS_TOKEN:-}${CURRENT_REFRESH_TOKEN:-}${CURRENT_CSRF_TOKEN:-}" in
    '') load_session || true;;
  esac
  return 0
}

# Fetch a CSRF token from the endpoint that issues them, keeping the cookie the
# server sets alongside it. Sets CURRENT_CSRF_TOKEN.
# Only needed when the API issues CSRF tokens out of band; an API that returns
# one from login is already covered by _capture_session.
get_csrf_token() {
  local response

  response=$(curl -s -c "$(_cookie_jar)" -b "$(_cookie_jar)" \
    "${API_BASE}${AUTH_CSRF_PATH:-/auth/csrf}" \
    ${ORIGIN:+-H "Origin: $ORIGIN"} \
    -A "$TEST_USER_AGENT" 2>/dev/null)

  CURRENT_CSRF_TOKEN=$(echo "$response" | jq -r "${AUTH_CSRF_JQ:-.csrfToken} // empty" 2>/dev/null)

  if [ -z "$CURRENT_CSRF_TOKEN" ]; then
    echo "get_csrf_token: nothing at '${AUTH_CSRF_JQ:-.csrfToken}' from ${AUTH_CSRF_PATH:-/auth/csrf}" >&2
    return 1
  fi
  _save_session
  return 0
}

# Register a user and keep the session it returns.
# Usage: register_user "email" "password" ['{"extra":"fields"}']
# Registration is normally a public endpoint: origin checking, no CSRF token.
register_user() {
  local email="$1"
  local password="${2:-${TEST_PASSWORD:-TestPassword123!}}"
  local extra="${3:-${AUTH_EXTRA_REGISTER_FIELDS:-${AUTH_EXTRA_LOGIN_FIELDS:-}}}"

  local json_file response http_code body
  json_file="$(_tmp_dir)/register.$$.json"
  auth_body "$email" "$password" "$extra" > "$json_file"

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X POST \
    "${API_BASE}${AUTH_REGISTER_PATH:-/auth/register}" \
    -H "Content-Type: application/json" \
    ${ORIGIN:+-H "Origin: $ORIGIN"} \
    -A "$TEST_USER_AGENT" \
    -c "$(_cookie_jar)" -b "$(_cookie_jar)" \
    -d "@$json_file" 2>/dev/null)

  rm -f "$json_file"
  http_code="$(get_http_code "$response")"
  body="$(get_response_body "$response")"
  _capture_session "$body"

  echo "$response"
  case "$http_code" in 200|201) return 0;; *) return 1;; esac
}

# Log in and keep the session.
# Usage: login_user "email" "password" ['{"extra":"fields"}']
login_user() {
  local email="$1"
  local password="${2:-${TEST_PASSWORD:-TestPassword123!}}"
  local extra="${3:-${AUTH_EXTRA_LOGIN_FIELDS:-}}"

  local json_file response http_code body
  json_file="$(_tmp_dir)/login.$$.json"
  auth_body "$email" "$password" "$extra" > "$json_file"

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X POST \
    "${API_BASE}${AUTH_LOGIN_PATH:-/auth/login}" \
    -H "Content-Type: application/json" \
    ${ORIGIN:+-H "Origin: $ORIGIN"} \
    -A "$TEST_USER_AGENT" \
    -c "$(_cookie_jar)" -b "$(_cookie_jar)" \
    -d "@$json_file" 2>/dev/null)

  rm -f "$json_file"
  http_code="$(get_http_code "$response")"
  body="$(get_response_body "$response")"
  _capture_session "$body"

  echo "$response"
  case "$http_code" in 200|201) return 0;; *) return 1;; esac
}

# One deliberately wrong credential, for lockout, rate limiting and audit
# suites. Echoes the response; never touches the session state, because a
# failed login must not look like a successful one to the rest of the suite.
login_wrong_password() {
  local email="$1"
  local extra="${2:-${AUTH_EXTRA_LOGIN_FIELDS:-}}"

  local json_file response
  json_file="$(_tmp_dir)/bad-login.$$.json"
  auth_body "$email" "${TEST_WRONG_PASSWORD:-WrongPassword123!}" "$extra" > "$json_file"

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X POST \
    "${API_BASE}${AUTH_LOGIN_PATH:-/auth/login}" \
    -H "Content-Type: application/json" \
    ${ORIGIN:+-H "Origin: $ORIGIN"} \
    -A "$TEST_USER_AGENT" \
    -d "@$json_file" 2>/dev/null)

  rm -f "$json_file"
  echo "$response"
}

# Exchange the refresh token for a new session, and keep whatever comes back —
# including a rotated refresh token, which is the whole point of the check: an
# API that rotates on refresh hands back a different token, and a suite that
# kept the old one tests replay instead of rotation.
# Usage: refresh_token ["refresh_token"] ["csrf_token"]
refresh_token() {
  _load_session_if_empty
  local refresh="${1-$CURRENT_REFRESH_TOKEN}"
  local csrf="${2-$CURRENT_CSRF_TOKEN}"

  local json_file response http_code body
  json_file="$(_tmp_dir)/refresh.$$.json"
  jq -n --arg f "${AUTH_REFRESH_FIELD:-refresh_token}" --arg t "$refresh" \
    '{($f): $t}' > "$json_file"

  _auth_headers "" "$csrf"
  [ -n "$refresh" ] && AUTH_ARGS+=(-b "${REFRESH_COOKIE:-refresh-token}=$refresh")

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X POST \
    "${API_BASE}${AUTH_REFRESH_PATH:-/auth/refresh}" \
    "${AUTH_ARGS[@]}" \
    -d "@$json_file" 2>/dev/null)

  rm -f "$json_file"
  http_code="$(get_http_code "$response")"
  body="$(get_response_body "$response")"
  [ "$http_code" = "200" ] && _capture_session "$body"

  echo "$response"
  [ "$http_code" = "200" ]
}

# End the session, and forget it locally only if the server agreed. A helper
# that clears its own state regardless would hide a logout that did nothing.
# Usage: logout ["access_token"] ["csrf_token"]
logout() {
  _load_session_if_empty
  local access="${1-$CURRENT_ACCESS_TOKEN}"
  local csrf="${2-$CURRENT_CSRF_TOKEN}"

  local response http_code
  _auth_headers "$access" "$csrf"
  [ -n "${CURRENT_REFRESH_TOKEN:-}" ] && AUTH_ARGS+=(-b "${REFRESH_COOKIE:-refresh-token}=$CURRENT_REFRESH_TOKEN")

  response=$(curl -s -w "\n${HTTP_STATUS_MARKER}%{http_code}---" -X POST \
    "${API_BASE}${AUTH_LOGOUT_PATH:-/auth/logout}" \
    "${AUTH_ARGS[@]}" 2>/dev/null)

  http_code="$(get_http_code "$response")"
  case "$http_code" in
    200|204)
      CURRENT_ACCESS_TOKEN=""
      CURRENT_REFRESH_TOKEN=""
      CURRENT_CSRF_TOKEN=""
      _save_session
      ;;
  esac

  echo "$response"
  case "$http_code" in 200|204) return 0;; *) return 1;; esac
}

# create_test_user, delete_test_user and random_email come from
# test-common.sh. create_test_user still echoes the response body, and now also
# leaves the session in CURRENT_* through _capture_session above; both still
# take the same arguments they took here.

# ====================================================================
# Account lockout  (optional — only for suites that test lockout)
# ====================================================================
# A lockout suite has to do three things the API does not expose: put an
# account back to zero, read the counter, and ask whether the account is
# locked. All three are SQL a project writes once, with {email} substituted:
#
#   AUTH_LOCKOUT_RESET_SQL     set the counter to 0 and clear the lock
#   AUTH_FAILED_ATTEMPTS_SQL   return the counter as a single value
#   AUTH_LOCKED_CHECK_SQL      return a truthy value when the account is locked
#
# Unset means the helper says so and skips, rather than inventing a schema.

_lockout_sql() {  # variable-name email
  local name="$1" email="$2" sql
  eval "sql=\${$name:-}"
  if [ -z "$sql" ]; then
    echo "$name not set — cannot manage lockout state for $email" >&2
    return 1
  fi
  printf '%s' "${sql//\{email\}/$email}"
}

# Put an account back to a clean slate before a lockout test.
reset_user_lockout() {
  local email="$1" sql
  sql="$(_lockout_sql AUTH_LOCKOUT_RESET_SQL "$email")" || return 1
  run_sql "$sql" > /dev/null
}

# The account's current failed-attempt count, as a bare number.
get_failed_attempts() {
  local email="$1" sql
  sql="$(_lockout_sql AUTH_FAILED_ATTEMPTS_SQL "$email")" || return 1
  run_sql "$sql" | tr -d '[:space:]'
}

# "true" or "false" — echoed rather than returned, so it reads the same in an
# assertion as it does in a message.
is_user_locked() {
  local email="$1" sql result
  sql="$(_lockout_sql AUTH_LOCKED_CHECK_SQL "$email")" || return 1
  result="$(run_sql "$sql" | tr -d '[:space:]')"
  case "$result" in
    t|true|TRUE|1) echo "true";;
    *)             echo "false";;
  esac
}

# Fail a login LOCKOUT_ATTEMPTS times, which is what every lockout suite does
# before asserting on the policy. The count is configured, not written in:
# the threshold is the project's policy, not the harness's.
trigger_account_lockout() {
  local email="$1"
  local attempts="${2:-${LOCKOUT_ATTEMPTS:-5}}"
  local i
  for i in $(seq 1 "$attempts"); do
    login_wrong_password "$email" > /dev/null 2>&1
  done
  echo "$attempts"
}

# ====================================================================
# Response parsing
# ====================================================================

# The status code a helper appended to a response.
get_http_code() {
  echo "$1" | grep "HTTP_STATUS" | sed 's/.*HTTP_STATUS:\([0-9]*\).*/\1/'
}

# The body without it.
get_response_body() {
  echo "$1" | grep -v "HTTP_STATUS"
}

# One field out of the body of such a response.
# Usage: get_json_field "$response" "user.id"
get_json_field() {
  local body
  body=$(get_response_body "$1")
  echo "$body" | jq -r ".$2 // empty" 2>/dev/null
}

# ====================================================================
# Metric Helpers  (Prometheus text format, when the service exposes it)
# ====================================================================

get_metric_value() {
  local metric_name="$1"

  curl -s -A "$TEST_USER_AGENT" "${API_BASE}${METRICS_PATH}" \
    | grep "^$metric_name " \
    | awk '{print $2}'
}

# Measure how much a counter moved across an action.
measure_metric_delta() {
  local metric_name="$1"
  local action_command="$2"

  local before after
  before=$(get_metric_value "$metric_name")
  eval "$action_command"
  after=$(get_metric_value "$metric_name")

  echo $(( ${after:-0} - ${before:-0} ))
}

# ====================================================================
# Assertions
# ====================================================================
# Every one of them records into the counters print_summary reports, and
# returns non-zero on failure so a suite can also stop where it matters.

# Assert the status code of a response captured with the status marker.
# Usage: assert_http_code "$response" 200 "Description"
assert_http_code() {
  local response="$1"
  local expected="$2"
  local description="${3:-HTTP status check}"

  local actual
  actual=$(get_http_code "$response")

  if [ "$actual" = "$expected" ]; then
    test_pass "$description (HTTP $actual)"
    return 0
  else
    test_fail "$description - expected HTTP $expected, got ${actual:-nothing}"
    return 1
  fi
}

# assert_json_equals comes from test-common.sh, which kept this file's
# explicit-response form — assert_json_equals "$response" field expected
# [description] — alongside the verbose framework's shorter one.

# assert_sql_equals comes from test-common.sh, and still prints the query and
# the result through show_sql and show_result above. test-framework.sh's
# assert_sql is the id-and-name form of the same assertion.

# --- small assertions the original methodology used constantly -----------------
assert_contains() { # haystack needle label — the response carries the value that was sent
  case "$1" in *"$2"*) echo "  PASS ${3:-contains $2}"; record_pass; return 0;; *) echo "  FAIL ${3:-contains $2} (not found: $2)"; record_fail; return 1;; esac
}
assert_not_empty() { # value label — an id, a token, a row came back at all
  if [ -n "$1" ]; then echo "  PASS ${2:-not empty}"; record_pass; return 0; else echo "  FAIL ${2:-not empty} (empty)"; record_fail; return 1; fi
}
assert_gte() { # actual minimum label — counts and totals, never asserted as "some"
  if [ "${1:-0}" -ge "${2:-0}" ] 2>/dev/null; then echo "  PASS ${3:-$1 >= $2}"; record_pass; return 0; else echo "  FAIL ${3:-$1 >= $2} (got ${1:-nothing})"; record_fail; return 1; fi
}
