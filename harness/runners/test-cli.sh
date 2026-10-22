#!/usr/bin/env bash
# ============================================================================
# {{PROJECT_NAME}} Test CLI
# ============================================================================
# One menu over everything the harness can do: run a regression, run a single
# suite, write an evidence report, read the results of an earlier run, look at
# the state of the system under test, switch environments, and put a
# configurable amount of load through one endpoint.
#
# It carries no test list and no endpoint of its own. Every suite it offers is
# a row in the manifest; every URL, port and credential comes from
# ../config/test-config.env. Running suites is delegated to the canonical
# runners rather than reimplemented here:
#
#   ../runners/run-all-critical-tests.sh   tiers, modes, terminal report
#   ../scripts/run-behavioral-tests.sh     the same run as a markdown report
#   ../scripts/calculate-coverage.js       how much of a document was executed
#
# Usage:
#   ./test-cli.sh                 interactive menu
#   ./test-cli.sh --list          print the suite inventory and exit
#   ./test-cli.sh --status        print the state of the system and exit
#   ./test-cli.sh --env DOCKER    select an environment first
#   ./test-cli.sh --help          this text
#
# Environment:
#   ACTIVE_ENV        LOCAL_DEV (default) | LOCAL_TEST | DOCKER
#   SUITES_DIR        where the suite scripts live
#   SUITES_MANIFEST   path to the manifest
#   TEST_RESULTS_DIR  where anything written goes (see ../lib/paths.sh)
#   TEST_CONFIG       an alternative to ../config/test-config.env
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${TEST_CONFIG:-$HARNESS_DIR/config/test-config.env}"

# Suites, manifest and results directory: one resolution, shared with every
# other runner, so no two of them disagree about where evidence is written.
# shellcheck source=../lib/paths.sh
. "$HARNESS_DIR/lib/paths.sh"
MANIFEST="$SUITES_MANIFEST"

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}
load_config

# The framework supplies the database and metric helpers used below. Without
# it the CLI still runs; the pieces that need it say so.
FRAMEWORK="$HARNESS_DIR/lib/test-framework.sh"
if [ -f "$FRAMEWORK" ]; then
  # shellcheck source=../lib/test-framework.sh
  . "$FRAMEWORK"
fi

# Optional progress flourish. Sourced with an explicit empty argument so its
# own "demo" check never sees this script's arguments.
PROGRESS_LIB="$HARNESS_DIR/lib/nyan-cat-progress.sh"
if [ -f "$PROGRESS_LIB" ]; then
  # shellcheck source=../lib/nyan-cat-progress.sh
  . "$PROGRESS_LIB" ""
fi

RUNNER="$HARNESS_DIR/runners/run-all-critical-tests.sh"
REPORTER="$HARNESS_DIR/scripts/run-behavioral-tests.sh"
SUITE_RUNNER="$HARNESS_DIR/runners/test-runner.sh"
COVERAGE_SCRIPT="$HARNESS_DIR/scripts/calculate-coverage.js"

# The rendered default lives in a variable: `${API_BASE:-{{...}}}` would
# append the extra braces to an API_BASE that is already set.
_default_api_base='{{API_BASE_URL}}'
API_BASE="${API_BASE:-$_default_api_base}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
METRICS_PATH="${METRICS_PATH:-/metrics}"
TEST_USER_AGENT="${TEST_USER_AGENT:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"
export TEST_USER_AGENT

# health_url comes from the framework. Define a fallback for the case where the
# framework is absent, so the health checks below still work.
if ! command -v health_url > /dev/null 2>&1; then
  health_url() {
    printf '%s' "${API_BASE%/}${HEALTH_PATH}"
  }
fi
if ! command -v db_configured > /dev/null 2>&1; then
  db_configured() { [ -n "${DB_NAME:-}" ] && command -v psql > /dev/null 2>&1; }
fi

# ANSI-C quoted, so a plain echo prints them: this script builds most of its
# output by interpolating them into ordinary strings.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

if [ "${ENABLE_COLORS:-true}" != "true" ] || [ ! -t 1 ]; then
  RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

# ============================================================================
# Inventory — the manifest, in file order
# ============================================================================

SUITE_TIERS=()
SUITE_TYPES=()
SUITE_FILES=()
SUITE_LABELS=()

load_manifest() {
  SUITE_TIERS=(); SUITE_TYPES=(); SUITE_FILES=(); SUITE_LABELS=()
  if [ ! -f "$MANIFEST" ]; then
    return 0
  fi
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    parse_manifest_line "$line" || continue
    SUITE_TIERS[${#SUITE_TIERS[@]}]="$MF_TIER"
    SUITE_TYPES[${#SUITE_TYPES[@]}]="$MF_TYPE"
    SUITE_FILES[${#SUITE_FILES[@]}]="$MF_FILE"
    SUITE_LABELS[${#SUITE_LABELS[@]}]="$MF_LABEL"
  done < "$MANIFEST"
}

suite_count() { echo "${#SUITE_FILES[@]}"; }

# Tier names in the order the runner executes them, deduplicated against what
# the manifest actually contains.
tiers_present() {
  local t seen="" i
  for i in $(seq 0 $(( $(suite_count) - 1 ))); do
    t="${SUITE_TIERS[$i]}"
    case " $seen " in *" $t "*) continue;; esac
    seen="$seen $t"
  done
  printf '%s' "${seen# }"
}

types_present() {
  local t seen="" i
  for i in $(seq 0 $(( $(suite_count) - 1 ))); do
    t="${SUITE_TYPES[$i]}"
    [ -n "$t" ] || continue
    case " $seen " in *" $t "*) continue;; esac
    seen="$seen $t"
  done
  printf '%s' "${seen# }"
}

# Suite files on disk that no manifest row names. They never run in a
# regression, which is the commonest way for a check to stop being evidence.
unlisted_suites() {
  [ -d "$SUITES_DIR" ] || return 0
  local path rel listed f i
  for path in "$SUITES_DIR"/*.sh "$SUITES_DIR"/*/*.sh; do
    [ -f "$path" ] || continue
    rel="${path#"$SUITES_DIR"/}"
    case "$rel" in _*|*/_*|*helpers*) continue;; esac
    listed=false
    for i in $(seq 0 $(( $(suite_count) - 1 ))); do
      f="${SUITE_FILES[$i]}"
      [ "$f" = "$rel" ] && { listed=true; break; }
    done
    [ "$listed" = false ] && echo "$rel"
  done
}

list_inventory() {
  if [ "$(suite_count)" -eq 0 ]; then
    echo "${YELLOW}No suites listed in $(basename "$MANIFEST").${NC}"
    echo "${DIM}Add rows as  tier|type|file|label  and they appear here.${NC}"
    echo ""
    return 0
  fi

  printf "%-5s %-16s %-10s %-9s %s\n" "#" "TIER" "TYPE" "STATUS" "SUITE"
  echo "──────────────────────────────────────────────────────────────────────"

  local i status
  for i in $(seq 0 $(( $(suite_count) - 1 ))); do
    if [ -f "$SUITES_DIR/${SUITE_FILES[$i]}" ]; then
      status="present"
    else
      status="MISSING"
    fi
    printf "%-5s %-16s %-10s %-9s %s\n" \
      "$((i + 1))" "${SUITE_TIERS[$i]}" "${SUITE_TYPES[$i]:-untyped}" \
      "$status" "${SUITE_LABELS[$i]}"
  done

  local extra
  extra="$(unlisted_suites)"
  if [ -n "$extra" ]; then
    echo ""
    echo "${YELLOW}Present but not in the manifest (never runs in a regression):${NC}"
    echo "$extra" | sed 's/^/  /'
  fi
  echo ""
}

# ============================================================================
# Input
# ============================================================================
# read -p writes its prompt to the terminal rather than to stdout, which is
# what lets the answer be captured with ask() in a command substitution.

ask() {
  local prompt_text="$1" default="${2:-}" answer=""
  if [ -n "$default" ]; then
    read -r -p "$prompt_text [$default]: " answer
    echo "${answer:-$default}"
  else
    read -r -p "$prompt_text: " answer
    echo "$answer"
  fi
}

confirm() {
  local answer=""
  read -r -p "$1 (y/n): " answer
  case "$answer" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

pause() {
  echo ""
  read -r -p "Press enter to continue..." _
}

is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1;;
    *) return 0;;
  esac
}

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
upper() { printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]'; }

# ============================================================================
# Display
# ============================================================================

clear_if_tty() {
  [ -t 1 ] || return 0
  clear 2>/dev/null || true
}

show_header() {
  clear_if_tty
  echo "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
  echo "${CYAN}║${NC}  ${BOLD}{{PROJECT_NAME}} — Test CLI${NC}"
  echo "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  ${CYAN}Environment:${NC} ${ACTIVE_ENV:-LOCAL_DEV}  ${DIM}${ENV_LABEL:-}${NC}"
  echo "  ${CYAN}API:${NC}         ${API_BASE}"
  if db_configured; then
    echo "  ${CYAN}Database:${NC}    ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-}"
  else
    echo "  ${CYAN}Database:${NC}    ${DIM}not configured${NC}"
  fi
  echo "  ${CYAN}Suites:${NC}      $SUITES_DIR ${DIM}($(suite_count) listed)${NC}"
  echo "  ${CYAN}Results:${NC}     $TEST_RESULTS_DIR"
  echo ""
}

show_menu() {
  echo "${YELLOW}────────────────────────────────────────────────────────────────────${NC}"
  echo "  ${BOLD}Run${NC}"
  echo "    ${YELLOW}1${NC}  Quick regression        ${DIM}essential tier${NC}"
  echo "    ${YELLOW}2${NC}  Standard regression     ${DIM}essential + core + extended${NC}"
  echo "    ${YELLOW}3${NC}  Full regression         ${DIM}every tier${NC}"
  echo "    ${YELLOW}4${NC}  Run one tier"
  echo "    ${YELLOW}5${NC}  Run one type            ${DIM}unit, e2e, api, ui, ...${NC}"
  echo "    ${YELLOW}6${NC}  Run one suite"
  echo ""
  echo "  ${BOLD}Record${NC}"
  echo "    ${YELLOW}7${NC}  Write an evidence report    ${DIM}markdown, for a closeout${NC}"
  echo "    ${YELLOW}8${NC}  Coverage of a verification document"
  echo "    ${YELLOW}9${NC}  Read an earlier result"
  echo ""
  echo "  ${BOLD}Inspect${NC}"
  echo "   ${YELLOW}10${NC}  Suite inventory         ${DIM}listed, missing, unlisted${NC}"
  echo "   ${YELLOW}11${NC}  System status           ${DIM}service, database, metrics${NC}"
  echo "   ${YELLOW}12${NC}  Show configuration"
  echo ""
  echo "  ${BOLD}Environment${NC}"
  echo "   ${YELLOW}13${NC}  Switch environment      ${DIM}LOCAL_DEV / LOCAL_TEST / DOCKER${NC}"
  echo "   ${YELLOW}14${NC}  Load check              ${DIM}N requests at a chosen concurrency${NC}"
  echo "   ${YELLOW}15${NC}  Clean up test data      ${DIM}needs TEST_CLEANUP_SQL${NC}"
  echo ""
  echo "${DIM}   [h] help   [0] exit${NC}"
  echo "${YELLOW}────────────────────────────────────────────────────────────────────${NC}"
  echo ""
}

show_cli_help() {
  clear_if_tty
  echo "${BOLD}How this works${NC}"
  echo ""
  echo "  Every suite offered here is a row in the manifest:"
  echo "    $MANIFEST"
  echo "  Every URL, port and credential comes from:"
  echo "    $CONFIG_FILE"
  echo ""
  echo "  ${BOLD}Modes${NC}"
  echo "    quick      the essential tier — is the system alive and is its core path intact"
  echo "    standard   essential + core + extended — the everyday regression"
  echo "    full       every tier, including security, integration and performance"
  echo ""
  echo "  ${BOLD}Statuses${NC}"
  echo "    EXECUTED — PASS    the suite ran and exited 0"
  echo "    EXECUTED — FAIL    the suite ran and exited non-zero"
  echo "    NOT EXECUTED       the suite was never run; it is not evidence of anything"
  echo ""
  echo "  A suite listed in the manifest whose file is missing is reported SKIP and"
  echo "  never counted as a pass. A suite file no manifest row names never runs in"
  echo "  a regression at all — option 10 lists those."
  echo ""
  echo "  ${BOLD}Also at the prompt${NC}"
  echo "    r          re-read the manifest, after editing it in another window"
  echo "    h          this text"
  echo "    0          exit"
  echo ""
  echo "  ${BOLD}Elsewhere${NC}"
  echo "    $SUITE_RUNNER"
  echo "      repeats one suite N times to catch a flake"
  echo "    $HARNESS_DIR/load/"
  echo "      the k6 capacity harness, for real load work"
  echo ""
  pause
}

usage() {
  sed -n '2,31p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ============================================================================
# Running
# ============================================================================

runner_available() {
  if [ ! -f "$RUNNER" ]; then
    echo "${RED}Runner not found: $RUNNER${NC}"
    return 1
  fi
  return 0
}

run_mode() {
  local mode="$1"
  runner_available || return 1
  clear_if_tty
  echo "${CYAN}Running the $mode regression...${NC}"
  echo ""
  bash "$RUNNER" "--$mode"
}

run_one_tier() {
  local tier present
  present="$(tiers_present)"
  echo ""
  [ -n "$present" ] && echo "${DIM}Tiers in the manifest: $present${NC}"
  tier="$(lower "$(ask "Tier" "essential")")"
  [ -n "$tier" ] || return 0
  runner_available || return 1
  bash "$RUNNER" --full --tier "$tier"
}

run_one_type() {
  local type present
  present="$(types_present)"
  echo ""
  if [ -n "$present" ]; then
    echo "${DIM}Types in the manifest: $present${NC}"
  else
    echo "${YELLOW}No manifest row declares a type — nothing can be selected by type.${NC}"
    return 0
  fi
  type="$(lower "$(ask "Type" "")")"
  [ -n "$type" ] || return 0
  runner_available || return 1
  bash "$RUNNER" --full --type "$type"
}

# One suite, logged beside every other result.
run_suite_index() {
  local n="$1"
  local i=$((n - 1))

  if ! is_number "$n" || [ "$i" -lt 0 ] || [ "$i" -ge "$(suite_count)" ]; then
    echo "${RED}No suite #$n${NC}"
    return 1
  fi

  local file="${SUITE_FILES[$i]}" label="${SUITE_LABELS[$i]}"
  local path="$SUITES_DIR/$file"

  if [ ! -f "$path" ]; then
    echo "${RED}Listed but missing: $path${NC}"
    echo "${DIM}A missing suite is NOT EXECUTED — it is never a pass.${NC}"
    return 1
  fi

  mkdir -p "$TEST_RESULTS_DIR"
  local stamp log start end rc
  stamp="$(date +%Y%m%d_%H%M%S)"
  log="$TEST_RESULTS_DIR/$(basename "$file" .sh)_${stamp}.log"

  echo "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo "${CYAN}Running: $label${NC}  ${DIM}($file)${NC}"
  echo "${CYAN}════════════════════════════════════════════════════════════════════${NC}"
  echo ""

  chmod +x "$path" 2>/dev/null || true
  start=$(date +%s)
  bash "$path" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  end=$(date +%s)

  echo ""
  if [ "$rc" -eq 0 ]; then
    echo "${GREEN}EXECUTED — PASS${NC}  $label  ${DIM}($((end - start))s)${NC}"
  else
    echo "${RED}EXECUTED — FAIL${NC}  $label  ${DIM}(exit $rc, $((end - start))s)${NC}"
  fi
  echo "${DIM}Output: $log${NC}"
  return "$rc"
}

pick_and_run_suite() {
  list_inventory
  [ "$(suite_count)" -eq 0 ] && return 0
  local n
  n="$(ask "Suite number" "")"
  [ -n "$n" ] || return 0
  run_suite_index "$n"
}

write_report() {
  if [ ! -f "$REPORTER" ]; then
    echo "${RED}Report script not found: $REPORTER${NC}"
    return 1
  fi
  local mode
  mode="$(lower "$(ask "Mode (quick/standard/full)" "standard")")"
  case "$mode" in
    quick|standard|full) ;;
    *) echo "${RED}Unknown mode: $mode${NC}"; return 1;;
  esac
  echo ""
  bash "$REPORTER" "--$mode"
}

coverage_report() {
  local doc
  doc="$(ask "Path to a verification document" "")"
  [ -n "$doc" ] || return 0
  if [ ! -f "$doc" ]; then
    echo "${RED}Not found: $doc${NC}"
    return 1
  fi
  if [ ! -f "$COVERAGE_SCRIPT" ]; then
    echo "${RED}Coverage script not found: $COVERAGE_SCRIPT${NC}"
    return 1
  fi
  if ! command -v node > /dev/null 2>&1; then
    echo "${RED}node is required for the coverage report${NC}"
    return 1
  fi
  TEST_RESULTS_DIR="$TEST_RESULTS_DIR" node "$COVERAGE_SCRIPT" "$doc"
}

# ============================================================================
# Reading what earlier runs produced
# ============================================================================

recent_results() {
  if [ ! -d "$TEST_RESULTS_DIR" ]; then
    echo "${YELLOW}No results directory yet: $TEST_RESULTS_DIR${NC}"
    return 0
  fi

  local listing
  listing="$(ls -t "$TEST_RESULTS_DIR" 2>/dev/null | head -20)"
  if [ -z "$listing" ]; then
    echo "${YELLOW}Nothing in $TEST_RESULTS_DIR yet. Run something first.${NC}"
    return 0
  fi

  echo "${BOLD}Most recent first:${NC}"
  echo ""
  local n=0 name
  RESULT_NAMES=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    RESULT_NAMES[${#RESULT_NAMES[@]}]="$name"
    printf "  %-4s %s\n" "$n" "$name"
  done <<EOF
$listing
EOF

  echo ""
  local pick
  pick="$(ask "Number to read (blank to go back)" "")"
  [ -n "$pick" ] || return 0
  is_number "$pick" || { echo "${RED}Not a number${NC}"; return 1; }
  local idx=$((pick - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#RESULT_NAMES[@]}" ]; then
    echo "${RED}No result #$pick${NC}"
    return 1
  fi

  local file="$TEST_RESULTS_DIR/${RESULT_NAMES[$idx]}"
  echo ""
  if [ -d "$file" ]; then
    ls -la "$file"
  elif command -v less > /dev/null 2>&1 && [ -t 1 ]; then
    less "$file"
  else
    cat "$file"
  fi
}

# ============================================================================
# The state of the system under test
# ============================================================================

system_status() {
  echo "${BOLD}Service${NC}"
  local url code
  url="$(health_url || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -A "$TEST_USER_AGENT" "$url" 2>/dev/null || true)"; code="${code:-000}"
  if [ "$code" = "200" ]; then
    echo "  ${GREEN}healthy${NC}  $url  ${DIM}(HTTP $code)${NC}"
  else
    echo "  ${RED}not answering${NC}  $url  ${DIM}(HTTP $code)${NC}"
  fi
  echo ""

  echo "${BOLD}Database${NC}"
  if ! db_configured; then
    echo "  ${DIM}not configured — set DB_NAME to enable the SQL helpers${NC}"
  elif psql -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" -U "${DB_USER:-${USER:-$(id -un 2>/dev/null || true)}}" \
            -d "$DB_NAME" -t -A -c "SELECT 1;" > /dev/null 2>&1; then
    echo "  ${GREEN}connected${NC}  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME}"
    local idle
    idle="$(psql -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" -U "${DB_USER:-${USER:-$(id -un 2>/dev/null || true)}}" \
      -d "$DB_NAME" -t -A -c \
      "SELECT COUNT(*) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND state = 'idle';" \
      2>/dev/null | tr -d '[:space:]')"
    [ -n "$idle" ] && echo "  ${DIM}idle connections: $idle${NC}"
    local stats
    stats="$(collect_database_stats 2>/dev/null)"
    if [ -n "$stats" ]; then
      echo ""
      echo "  ${BOLD}DB_STATS_QUERIES${NC}"
      echo "$stats" | sed 's/^/    /'
    else
      echo "  ${DIM}DB_STATS_QUERIES is empty — nothing to report as evidence${NC}"
    fi
  else
    echo "  ${RED}cannot connect${NC}  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME}"
  fi
  echo ""

  echo "${BOLD}Cache${NC}"
  if command -v redis-cli > /dev/null 2>&1; then
    if redis-cli -h "${REDIS_HOST:-localhost}" -p "${REDIS_PORT:-6379}" ping > /dev/null 2>&1; then
      echo "  ${GREEN}reachable${NC}  ${REDIS_HOST:-localhost}:${REDIS_PORT:-6379}"
    else
      echo "  ${YELLOW}not answering${NC}  ${REDIS_HOST:-localhost}:${REDIS_PORT:-6379}"
    fi
  else
    echo "  ${DIM}redis-cli not installed — skipped${NC}"
  fi
  echo ""

  echo "${BOLD}Metrics${NC}"
  if [ -z "${API_STAT_METRICS:-}" ]; then
    echo "  ${DIM}API_STAT_METRICS is empty — set it to the metric names worth watching${NC}"
  else
    local metrics
    metrics="$(collect_api_stats 2>/dev/null)"
    if [ -n "$metrics" ]; then
      echo "$metrics" | sed 's/^/  /'
    else
      echo "  ${DIM}no metrics returned from ${API_BASE}${METRICS_PATH}${NC}"
    fi
  fi
  echo ""
}

show_configuration() {
  echo "${BOLD}Environment${NC}"
  printf "  %-20s %s\n" "ACTIVE_ENV" "${ACTIVE_ENV:-LOCAL_DEV}"
  printf "  %-20s %s\n" "ENV_LABEL" "${ENV_LABEL:-}"
  echo ""
  echo "${BOLD}Endpoints${NC}"
  printf "  %-20s %s\n" "API_BASE" "${API_BASE:-}"
  printf "  %-20s %s\n" "ORIGIN" "${ORIGIN:-}"
  printf "  %-20s %s\n" "HEALTH_PATH" "${HEALTH_PATH:-}"
  printf "  %-20s %s\n" "METRICS_PATH" "${METRICS_PATH:-}"
  echo ""
  echo "${BOLD}Data stores${NC}"
  printf "  %-20s %s\n" "DB" "${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-none}"
  printf "  %-20s %s\n" "REDIS" "${REDIS_HOST:-}:${REDIS_PORT:-}"
  echo ""
  echo "${BOLD}Paths${NC}"
  printf "  %-20s %s\n" "config" "$CONFIG_FILE"
  printf "  %-20s %s\n" "SUITES_DIR" "$SUITES_DIR"
  printf "  %-20s %s\n" "SUITES_MANIFEST" "$MANIFEST"
  printf "  %-20s %s\n" "TEST_RESULTS_DIR" "$TEST_RESULTS_DIR"
  echo ""
  echo "${BOLD}Optional blocks${NC}"
  printf "  %-20s %s\n" "AUTH_LOGIN_PATH" "${AUTH_LOGIN_PATH:-unset}"
  printf "  %-20s %s\n" "DB_STATS_QUERIES" "$([ -n "${DB_STATS_QUERIES:-}" ] && echo configured || echo empty)"
  printf "  %-20s %s\n" "API_STAT_METRICS" "$([ -n "${API_STAT_METRICS:-}" ] && echo "${API_STAT_METRICS}" || echo empty)"
  printf "  %-20s %s\n" "TEST_PREP_SQL" "$([ -n "${TEST_PREP_SQL:-}" ] && echo configured || echo empty)"
  printf "  %-20s %s\n" "TEST_CLEANUP_SQL" "$([ -n "${TEST_CLEANUP_SQL:-}" ] && echo configured || echo empty)"
  echo ""
}

# ============================================================================
# Environment switching
# ============================================================================

# The config file fills every value with ${VAR:-default}, so an already
# exported value survives a re-source. Clearing them first is what makes the
# switch real rather than cosmetic.
apply_env() {
  local want
  want="$(upper "${1:-}")"
  case "$want" in
    LOCAL_DEV|LOCAL_TEST|DOCKER) ;;
    *) echo "${RED}Unknown environment: ${1:-}${NC}  ${DIM}(LOCAL_DEV, LOCAL_TEST, DOCKER)${NC}"; return 1;;
  esac

  unset API_BASE ORIGIN DB_HOST DB_PORT DB_USER DB_PASS DB_NAME \
        REDIS_HOST REDIS_PORT PGPASSWORD ENV_LABEL
  ACTIVE_ENV="$want"
  export ACTIVE_ENV
  load_config

  API_BASE="${API_BASE:-$_default_api_base}"
  HEALTH_PATH="${HEALTH_PATH:-/health}"
  METRICS_PATH="${METRICS_PATH:-/metrics}"
  return 0
}

switch_environment() {
  echo "  ${YELLOW}1${NC}  LOCAL_DEV    ${DIM}the stack you run on your machine${NC}"
  echo "  ${YELLOW}2${NC}  LOCAL_TEST   ${DIM}the same stack against a throwaway database${NC}"
  echo "  ${YELLOW}3${NC}  DOCKER       ${DIM}the stack running in containers${NC}"
  echo ""
  local pick target
  pick="$(ask "Environment" "1")"
  case "$pick" in
    1|LOCAL_DEV|local_dev)   target="LOCAL_DEV";;
    2|LOCAL_TEST|local_test) target="LOCAL_TEST";;
    3|DOCKER|docker)         target="DOCKER";;
    *) echo "${RED}Unknown selection${NC}"; return 1;;
  esac
  apply_env "$target" || return 1
  echo ""
  echo "${GREEN}Now pointed at ${ACTIVE_ENV}${NC}  ${DIM}${ENV_LABEL:-}${NC}"
  echo "  API: ${API_BASE}"
  db_configured && echo "  DB:  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-}"
}

# ============================================================================
# Load check
# ============================================================================
# Enough to answer "does this endpoint hold up at N in flight" without leaving
# the harness. It is not the capacity harness: for a real load profile, arrival
# rates, thresholds and server-side metrics, use harness/load with k6.

show_load_progress() {
  local current="$1" total="$2"
  [ -t 1 ] || return 0
  if command -v nyan_progress > /dev/null 2>&1; then
    nyan_progress "$current" "$total"
  else
    printf "\r  %3d%% (%d/%d)" $((current * 100 / total)) "$current" "$total"
  fi
}

load_check() {
  local path method count concurrency body url
  path="$(ask "Path (appended to API_BASE)" "${HEALTH_PATH:-/health}")"
  method="$(upper "$(ask "Method" "GET")")"
  count="$(ask "How many requests" "50")"
  concurrency="$(ask "How many in flight" "5")"

  is_number "$count" && [ "$count" -gt 0 ] || { echo "${RED}Request count must be a positive number${NC}"; return 1; }
  is_number "$concurrency" && [ "$concurrency" -gt 0 ] || { echo "${RED}Concurrency must be a positive number${NC}"; return 1; }

  body=""
  case "$method" in
    GET|HEAD|DELETE) ;;
    *) body="$(ask "JSON body (blank for none)" "")";;
  esac

  case "$path" in
    http://*|https://*) url="$path";;
    /*)                 url="${API_BASE%/}$path";;
    *)                  url="${API_BASE%/}/$path";;
  esac

  echo ""
  echo "${MAGENTA}$count $method requests to $url, $concurrency in flight${NC}"
  if ! confirm "Send them?"; then
    return 0
  fi
  echo ""

  local work
  tmpbase="${TMPDIR:-/tmp}"; work="$(mktemp -d "${tmpbase%/}/harness-load.XXXXXX")" || return 1

  # One argument list, built once: an Origin header only when one is
  # configured, a body only when the method takes one.
  local -a curl_args
  curl_args=(-s -o /dev/null -w '%{http_code} %{time_total}\n'
             -X "$method" -A "$TEST_USER_AGENT")
  [ -n "${ORIGIN:-}" ] && curl_args+=(-H "Origin: $ORIGIN")
  [ -n "$body" ] && curl_args+=(-H "Content-Type: application/json" -d "$body")

  local sent start end elapsed
  start=$(date +%s)
  sent=1
  while [ "$sent" -le "$count" ]; do
    ( curl "${curl_args[@]}" "$url" 2>/dev/null || echo "000 0" ) > "$work/$sent" &

    if [ $((sent % concurrency)) -eq 0 ]; then
      wait
      show_load_progress "$sent" "$count"
    fi
    sent=$((sent + 1))
  done
  wait
  show_load_progress "$count" "$count"
  end=$(date +%s)
  elapsed=$((end - start))
  [ "$elapsed" -lt 1 ] && elapsed=1

  cat "$work"/* > "$work/all.txt" 2>/dev/null

  echo ""
  echo ""
  echo "${BOLD}Load check results${NC}"
  echo "  URL:          $url"
  echo "  Requests:     $count"
  echo "  Responses:    $(wc -l < "$work/all.txt" | tr -d '[:space:]')"
  echo "  In flight:    $concurrency"
  echo "  Duration:     ${elapsed}s"
  awk '{ printf "%.6f\n", $2 }' "$work/all.txt" | sort -n > "$work/times.txt"
  awk -v total="$count" -v secs="$elapsed" '
    { n++; sum += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
    END {
      if (n == 0) { print "  no timings were recorded"; exit }
      printf "  Throughput:   %.1f req/s\n", total / secs
      printf "  Mean:         %d ms\n", (sum / n) * 1000
      printf "  Min / Max:    %d ms / %d ms\n", min * 1000, max * 1000
    }' "$work/times.txt"
  awk '
    { t[NR] = $1 }
    END {
      if (NR == 0) exit
      p50 = t[int(NR * 0.50) + (NR * 0.50 == int(NR * 0.50) ? 0 : 1)]
      p95 = t[int(NR * 0.95) + (NR * 0.95 == int(NR * 0.95) ? 0 : 1)]
      p99 = t[int(NR * 0.99) + (NR * 0.99 == int(NR * 0.99) ? 0 : 1)]
      printf "  p50/p95/p99:  %d ms / %d ms / %d ms\n", p50 * 1000, p95 * 1000, p99 * 1000
    }' "$work/times.txt"

  echo ""
  echo "  ${BOLD}Status codes${NC}"
  awk '{ print $1 }' "$work/all.txt" | sort | uniq -c | sort -rn | while read -r n code; do
    case "$code" in
      2*) printf "    %s%-4s%s %s\n" "$GREEN" "$code" "$NC" "$n";;
      000) printf "    %s%-4s%s %s  %sno response%s\n" "$RED" "$code" "$NC" "$n" "$DIM" "$NC";;
      5*) printf "    %s%-4s%s %s\n" "$RED" "$code" "$NC" "$n";;
      *)  printf "    %s%-4s%s %s\n" "$YELLOW" "$code" "$NC" "$n";;
    esac
  done
  echo ""
  echo "  ${DIM}For arrival rates, thresholds and server-side metrics use${NC}"
  echo "  ${DIM}$HARNESS_DIR/load — see load/RUNBOOK.md${NC}"

  rm -rf "$work"
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup_test_data() {
  if [ -z "${TEST_CLEANUP_SQL:-}" ]; then
    echo "${YELLOW}TEST_CLEANUP_SQL is not set.${NC}"
    echo ""
    echo "There is no safe guess for what a project considers test data, so"
    echo "nothing is deleted. Set it in $CONFIG_FILE, for example:"
    echo ""
    echo "  ${DIM}export TEST_CLEANUP_SQL=\"DELETE FROM users WHERE email LIKE 'harness_%';\"${NC}"
    echo ""
    return 0
  fi

  if ! db_configured; then
    echo "${RED}No database configured (set DB_NAME) — nothing to clean up.${NC}"
    return 1
  fi

  echo "${BOLD}This will run, against ${DB_NAME}:${NC}"
  echo ""
  echo "$TEST_CLEANUP_SQL" | sed 's/^/  /'
  echo ""
  if ! confirm "Run it?"; then
    echo "Nothing was deleted."
    return 0
  fi

  if psql -h "${DB_HOST:-localhost}" -p "${DB_PORT:-5432}" -U "${DB_USER:-${USER:-$(id -un 2>/dev/null || true)}}" \
          -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "$TEST_CLEANUP_SQL"; then
    echo "${GREEN}Cleanup applied.${NC}"
  else
    echo "${RED}Cleanup failed — nothing was rolled back automatically.${NC}"
    return 1
  fi
}

# ============================================================================
# Entry
# ============================================================================

PRESELECT_ENV=""
DO_LIST=0
DO_STATUS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --list)    DO_LIST=1; shift;;
    --status)  DO_STATUS=1; shift;;
    --env)     PRESELECT_ENV="${2:-}"; shift 2;;
    *) echo "unknown argument: $1" >&2; echo "try --help" >&2; exit 2;;
  esac
done

if [ -n "$PRESELECT_ENV" ]; then
  apply_env "$PRESELECT_ENV" || exit 2
fi

load_manifest

if [ "$DO_LIST" -eq 1 ]; then
  echo "Environment: ${ACTIVE_ENV:-LOCAL_DEV}   Suites: $SUITES_DIR"
  echo "Manifest:    $MANIFEST"
  echo ""
  list_inventory
  exit 0
fi

if [ "$DO_STATUS" -eq 1 ]; then
  echo "Environment: ${ACTIVE_ENV:-LOCAL_DEV}   API: ${API_BASE}"
  echo ""
  system_status
  exit 0
fi

if [ ! -t 0 ]; then
  echo "test-cli: no terminal to read from." >&2
  echo "Use --list, --status, or one of the non-interactive runners:" >&2
  echo "  $RUNNER --quick|--standard|--full" >&2
  echo "  $REPORTER --standard" >&2
  exit 2
fi

trap 'echo ""; exit 0' INT TERM

while true; do
  show_header
  show_menu

  choice="$(ask "Select option" "")"

  case "$(lower "$choice")" in
    1)  run_mode quick;         pause;;
    2)  run_mode standard;      pause;;
    3)  run_mode full;          pause;;
    4)  run_one_tier;           pause;;
    5)  run_one_type;           pause;;
    6)  pick_and_run_suite;     pause;;
    7)  write_report;           pause;;
    8)  coverage_report;        pause;;
    9)  recent_results;         pause;;
    10) clear_if_tty; list_inventory; pause;;
    11) clear_if_tty; system_status;  pause;;
    12) clear_if_tty; show_configuration; pause;;
    13) switch_environment;     pause;;
    14) load_check;             pause;;
    15) cleanup_test_data;      pause;;
    h|help) show_cli_help;;
    r|reload) load_manifest; echo "${GREEN}Manifest reloaded${NC}"; sleep 1;;
    0|q|quit|exit) echo ""; exit 0;;
    "") ;;
    *) echo "${RED}No such option: $choice${NC}"; sleep 1;;
  esac
done
