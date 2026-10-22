#!/bin/bash
# ============================================================================
# CANONICAL TEST RUNNER — behavioral regression
# ============================================================================
# This is the runner to reach for. It runs the suites listed in the manifest,
# tier by tier, and prints one report. It carries no suite list of its own:
# everything it knows comes from the manifest and the suites directory.
#
# Its flags are the canonical vocabulary; the other manifest-driven script
# (../scripts/run-behavioral-tests.sh, which writes a markdown evidence report
# instead of terminal output) accepts the same ones.
#
# Usage: ./run-all-critical-tests.sh [OPTIONS]
#
# Modes (which tiers run):
#   --quick       essential tier only
#   --standard    essential + core + extended (default)
#   --full        every tier
#
# Options:
#   --verbose     Show full output from each suite        (env VERBOSE=true)
#   --no-prep     Skip environment preparation
#   --stop-fail   Stop on the first suite failure         (env STOP_ON_FAIL=true)
#   --show-config Print the loaded configuration first    (env SHOW_CONFIG=true)
#   --list        List the suites that would run — and the suite files present
#                 but unlisted, which no regression ever runs — then exit
#   -h, --help    Print this header and exit
#   --tier X      Run only tier X (e.g. --tier security)
#   --type X      Run only suites of type X (e.g. --type unit). Composes with
#                 --tier and with the modes.
#   --include-unlisted
#                 Also run the suite files present in the suites directory that
#                 no manifest row names, as a final "unlisted" tier. For a
#                 project whose manifest is not filled in yet; the manifest
#                 stays the thing a regression is defined by.
#
# Environment:
#   ACTIVE_ENV        LOCAL_DEV (default) | LOCAL_TEST | DOCKER
#   SUITES_DIR        where the suite scripts live
#   SUITES_MANIFEST   path to the manifest
#   TEST_RESULTS_DIR  where anything written goes (see ../lib/paths.sh)
#   VERBOSE           true is the same as --verbose
#   STOP_ON_FAIL      true is the same as --stop-fail
#   SHOW_CONFIG       true is the same as --show-config
#   See config/test-config.env for the rest.
#
# Between tiers it puts the system back into a known state — the cache flush
# and the prep SQL the project configured, then a connection-pool check — so a
# tier is not failed by what the tier before it left behind. Both are inert
# until REDIS_FLUSH or TEST_PREP_SQL is configured.
# ============================================================================

set +e  # a failing suite must not abort the run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${TEST_CONFIG:-$SCRIPT_DIR/../config/test-config.env}"

# Suites, manifest and results directory all come from one place, so no two
# scripts can disagree about where evidence is written.
# shellcheck source=../lib/paths.sh
. "$SCRIPT_DIR/../lib/paths.sh"
MANIFEST="$SUITES_MANIFEST"

# ============================================================================
# ARGUMENTS
# ============================================================================
# Parsed before the configuration is loaded, so --verbose and --show-config
# reach the configuration file itself. The environment forms (VERBOSE,
# STOP_ON_FAIL, SHOW_CONFIG) are the defaults; a flag overrides them.
MODE="standard"
case "${VERBOSE:-}" in true|1|yes) VERBOSE=true;; *) VERBOSE=false;; esac
case "${STOP_ON_FAIL:-}" in true|1|yes) STOP_ON_FAIL=true;; *) STOP_ON_FAIL=false;; esac
case "${SHOW_CONFIG:-}" in true|1|yes) SHOW_CONFIG=true;; *) SHOW_CONFIG=false;; esac
SKIP_PREP=false
LIST_ONLY=false
INCLUDE_UNLISTED=false
FILTER_TIER=""
FILTER_TYPE=""
NEXT_IS=""

for arg in "$@"; do
    case $arg in
        --quick)      MODE="quick" ;;
        --standard)   MODE="standard" ;;
        --full)       MODE="full" ;;
        --verbose)    VERBOSE=true ;;
        --no-prep)    SKIP_PREP=true ;;
        --stop-fail)  STOP_ON_FAIL=true ;;
        --show-config) SHOW_CONFIG=true ;;
        --list)       LIST_ONLY=true ;;
        --include-unlisted) INCLUDE_UNLISTED=true ;;
        --tier)       NEXT_IS="tier" ;;
        --type)       NEXT_IS="type" ;;
        -h|--help)    awk 'NR>1 && /^#/ {sub(/^#[ ]?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)
            case "$NEXT_IS" in
                tier) FILTER_TIER="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')";;
                type) FILTER_TYPE="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')";;
            esac
            NEXT_IS=""
            ;;
    esac
done
export VERBOSE STOP_ON_FAIL SHOW_CONFIG

# Source configuration
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Where the service is, whether a database is configured, how to release a
# congested pool and how to put the system back into a known state — one copy,
# shared with the suites' own libraries.
# shellcheck source=../lib/test-env.sh
. "$SCRIPT_DIR/../lib/test-env.sh"
export TEST_USER_AGENT

# Results tracking
declare -a PASSED_SUITES
declare -a FAILED_SUITES
declare -a SKIPPED_SUITES
START_TIME=$(date +%s)

# Set once --stop-fail has fired. Every tier checks it, because a tier is
# invoked as `run_tier ... || true` — the `|| true` is what keeps one tier's
# failure from aborting the summary, and it would equally swallow the signal
# to stop. The flag is the signal that survives it.
RUN_ABORTED=false

# ============================================================================
# SUITE INVENTORY — from the manifest (tier|type|file|label)
# ============================================================================
# Each entry is "file:type:label". Reading it back with three `read` variables
# leaves any colon in the label where it belongs, in the label.
ESSENTIAL_TESTS=()
CORE_TESTS=()
EXTENDED_TESTS=()
SECURITY_TESTS=()
INTEGRATION_TESTS=()
PERFORMANCE_TESTS=()
INFRASTRUCTURE_TESTS=()
RECENT_TESTS=()
UNLISTED_TESTS=()

load_manifest() {
    [ -f "$MANIFEST" ] || { echo "No suite manifest at $MANIFEST — add tier|type|file|label lines."; return 0; }
    local line entry
    while IFS= read -r line || [ -n "$line" ]; do
        parse_manifest_line "$line" || continue
        entry="$MF_FILE:$MF_TYPE:$MF_LABEL"
        case "$MF_TIER" in
            essential)      ESSENTIAL_TESTS+=("$entry");;
            core)           CORE_TESTS+=("$entry");;
            extended)       EXTENDED_TESTS+=("$entry");;
            security)       SECURITY_TESTS+=("$entry");;
            integration)    INTEGRATION_TESTS+=("$entry");;
            performance)    PERFORMANCE_TESTS+=("$entry");;
            infrastructure) INFRASTRUCTURE_TESTS+=("$entry");;
            recent)         RECENT_TESTS+=("$entry");;
            *) echo "unknown tier '$MF_TIER' in manifest (line: $MF_FILE)";;
        esac
    done < "$MANIFEST"
}
load_manifest

# ============================================================================
# FUNCTIONS
# ============================================================================

print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# db_configured, release_idle_db_connections, recover_db_pool and
# reset_test_environment all come from ../lib/test-env.sh.

run_suite() {
    local file="$1"
    local name="$2"
    local full_path="$SUITES_DIR/$file"

    if [ ! -f "$full_path" ]; then
        echo -e "  ${YELLOW}SKIP${NC} $name ${DIM}(file not found)${NC}"
        SKIPPED_SUITES+=("$name")
        return 0
    fi

    chmod +x "$full_path" 2>/dev/null || true

    local suite_start elapsed
    suite_start=$(date +%s)
    echo -ne "  ${BLUE}RUN ${NC} $name..."

    if [ "$VERBOSE" = true ]; then
        echo ""
        if "$full_path" 2>&1; then
            elapsed=$(( $(date +%s) - suite_start ))
            echo -e "  ${GREEN}PASS${NC} $name ${DIM}(${elapsed}s)${NC}"
            PASSED_SUITES+=("$name")
        else
            elapsed=$(( $(date +%s) - suite_start ))
            echo -e "  ${RED}FAIL${NC} $name ${DIM}(${elapsed}s)${NC}"
            FAILED_SUITES+=("$name")
            if [ "$STOP_ON_FAIL" = true ]; then
                echo -e "\n  ${RED}--stop-fail: aborting remaining suites${NC}"
                RUN_ABORTED=true
                return 1
            fi
        fi
    else
        local log_file
        # an explicit template: BSD mktemp treats -t as a prefix, GNU mktemp
        # requires the XXXXXX and rejects a bare prefix.
        tmpbase="${TMPDIR:-/tmp}"; log_file="$(mktemp "${tmpbase%/}/harness-suite.XXXXXX")"
        if "$full_path" > "$log_file" 2>&1; then
            elapsed=$(( $(date +%s) - suite_start ))
            echo -e "\r  ${GREEN}PASS${NC} $name ${DIM}(${elapsed}s)${NC}                    "
            PASSED_SUITES+=("$name")
        else
            elapsed=$(( $(date +%s) - suite_start ))
            echo -e "\r  ${RED}FAIL${NC} $name ${DIM}(${elapsed}s)${NC}                    "
            FAILED_SUITES+=("$name")
            echo -e "    ${YELLOW}Last output:${NC}"
            tail -5 "$log_file" 2>/dev/null | sed 's/^/    /'
            if [ "$STOP_ON_FAIL" = true ]; then
                rm -f "$log_file"
                echo -e "\n  ${RED}--stop-fail: aborting remaining suites${NC}"
                RUN_ABORTED=true
                return 1
            fi
        fi
        rm -f "$log_file"
    fi

    release_idle_db_connections
    return 0
}

run_tier() {
    local tier_name="$1"
    shift
    local tests=("$@")

    [ "$RUN_ABORTED" = true ] && return 0
    [ ${#tests[@]} -eq 0 ] && return 0

    if [ -n "$FILTER_TIER" ]; then
        local tier_lower filter_lower
        tier_lower=$(echo "$tier_name" | tr '[:upper:]' '[:lower:]')
        filter_lower=$(echo "$FILTER_TIER" | tr '[:upper:]' '[:lower:]')
        [ "$tier_lower" = "$filter_lower" ] || return 0
    fi

    # --type narrows within the tier; an untyped manifest row is never selected
    # by it, because nothing says what kind of test it is. A tier that nothing
    # matches prints no header rather than an empty one.
    local test file type name selected=()
    for test in "${tests[@]}"; do
        IFS=':' read -r file type name <<< "$test"
        [ -n "$FILTER_TYPE" ] && [ "$type" != "$FILTER_TYPE" ] && continue
        selected+=("$file:$name")
    done
    [ ${#selected[@]} -eq 0 ] && return 0

    print_header "TIER: $(echo "$tier_name" | tr '[:lower:]' '[:upper:]')"

    for test in "${selected[@]}"; do
        IFS=':' read -r file name <<< "$test"
        run_suite "$file" "$name" || return 1
    done
    return 0
}

list_suites() {
    local tier="$1"
    shift
    local tests=("$@")

    [ ${#tests[@]} -eq 0 ] && return

    echo -e "\n${CYAN}$tier${NC} (${#tests[@]} suites):"
    local test file type name
    for test in "${tests[@]}"; do
        IFS=':' read -r file type name <<< "$test"
        [ -n "$FILTER_TYPE" ] && [ "$type" != "$FILTER_TYPE" ] && continue
        if [ -f "$SUITES_DIR/$file" ]; then
            echo -e "  ${GREEN}OK${NC}   $file  ${DIM}[${type:-untyped}] -> $name${NC}"
        else
            echo -e "  ${YELLOW}MISS${NC} $file  ${DIM}[${type:-untyped}] -> $name${NC}"
        fi
    done
}

# Suite files on disk that no manifest row names — answered by the shared
# resolver in ../lib/paths.sh, so the report script and the interactive runner
# cannot come to a different answer about the same directory.
collect_unlisted() {
    unlisted_suite_files "$MANIFEST"
}

list_unlisted_suites() {
    local rel found=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ "$found" -eq 0 ] && echo -e "\n${YELLOW}Present but not in the manifest (never runs in a regression):${NC}"
        found=1
        echo -e "  ${YELLOW}--${NC}   $rel"
    done <<EOF
$(collect_unlisted)
EOF
}

# --include-unlisted turns those files into a final tier, so a project whose
# manifest is not filled in yet can still run everything it has written.
load_unlisted() {
    local rel
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        UNLISTED_TESTS+=("$rel::$rel")
    done <<EOF
$(collect_unlisted)
EOF
}

# ============================================================================
# ENVIRONMENT PREPARATION
# ============================================================================

prepare_environment() {
    echo -e "${MAGENTA}  Preparing test environment...${NC}"

    # Health check, known-state reset, pool check — one implementation, in
    # ../lib/test-env.sh, so the report script does exactly the same thing.
    # A non-zero return means the service is not there: nothing below could
    # mean anything, so the run stops rather than reporting failures.
    if ! prepare_test_environment; then
        echo -e "  ${RED}Start the service under test, then run this again.${NC}"
        exit 1
    fi

    echo ""
}

# Between tiers: release a congested pool and put the system back into the
# state the next tier expects. The suites that just ran are what built the
# state that would otherwise fail the next ones, which is why this happens at
# every tier boundary rather than once at the start.
between_tiers() {
    [ "$RUN_ABORTED" = true ] && return 0
    recover_db_pool
    reset_test_environment
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

if [ "$LIST_ONLY" = true ]; then
    echo -e "${BOLD}Available Test Suites${NC}"
    echo -e "${DIM}Environment: ${ACTIVE_ENV:-LOCAL_DEV}  Suites: $SUITES_DIR${NC}"

    list_suites "ESSENTIAL (--quick)"          "${ESSENTIAL_TESTS[@]}"
    list_suites "CORE (--standard)"            "${CORE_TESTS[@]}"
    list_suites "EXTENDED (--standard)"        "${EXTENDED_TESTS[@]}"
    list_suites "SECURITY (--full)"            "${SECURITY_TESTS[@]}"
    list_suites "INTEGRATION (--full)"         "${INTEGRATION_TESTS[@]}"
    list_suites "PERFORMANCE (--full)"         "${PERFORMANCE_TESTS[@]}"
    list_suites "INFRASTRUCTURE (--full)"      "${INFRASTRUCTURE_TESTS[@]}"
    list_suites "RECENT (--full)"              "${RECENT_TESTS[@]}"

    if [ "$INCLUDE_UNLISTED" = true ]; then
        load_unlisted
        list_suites "UNLISTED (--include-unlisted)" "${UNLISTED_TESTS[@]}"
    else
        list_unlisted_suites
    fi

    TOTAL_QUICK=${#ESSENTIAL_TESTS[@]}
    TOTAL_STANDARD=$((TOTAL_QUICK + ${#CORE_TESTS[@]} + ${#EXTENDED_TESTS[@]}))
    TOTAL_FULL=$((TOTAL_STANDARD + ${#SECURITY_TESTS[@]} + ${#INTEGRATION_TESTS[@]} + ${#PERFORMANCE_TESTS[@]} + ${#INFRASTRUCTURE_TESTS[@]} + ${#RECENT_TESTS[@]}))
    echo -e "\n${BOLD}Totals:${NC} --quick=$TOTAL_QUICK  --standard=$TOTAL_STANDARD  --full=$TOTAL_FULL"
    [ -n "$FILTER_TYPE" ] && echo -e "${DIM}(listing narrowed to --type $FILTER_TYPE)${NC}"
    exit 0
fi

# Banner
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}{{PROJECT_NAME}} — BEHAVIORAL REGRESSION SUITE${NC}"
echo -e "${CYAN}║${NC}  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "${CYAN}║${NC}  Mode: ${BOLD}$(echo "$MODE" | tr '[:lower:]' '[:upper:]')${NC}  Env: ${BOLD}${ACTIVE_ENV:-LOCAL_DEV}${NC}${FILTER_TYPE:+  Type: ${BOLD}$FILTER_TYPE${NC}}"
echo -e "${CYAN}║${NC}  API: ${DIM}${API_BASE}${NC}"
if db_configured; then
    echo -e "${CYAN}║${NC}  DB: ${DIM}${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}${NC}"
fi
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"

if [ "$SKIP_PREP" = false ]; then
    prepare_environment
fi

# --- essential: every mode --------------------------------------------------
run_tier "essential" "${ESSENTIAL_TESTS[@]}" || true

# --- standard: core + extended ---------------------------------------------
if [ "$MODE" = "standard" ] || [ "$MODE" = "full" ]; then
    between_tiers
    run_tier "core" "${CORE_TESTS[@]}" || true
    between_tiers
    run_tier "extended" "${EXTENDED_TESTS[@]}" || true
fi

# --- full: everything else --------------------------------------------------
if [ "$MODE" = "full" ]; then
    between_tiers
    run_tier "security" "${SECURITY_TESTS[@]}" || true
    between_tiers
    run_tier "integration" "${INTEGRATION_TESTS[@]}" || true
    between_tiers
    run_tier "performance" "${PERFORMANCE_TESTS[@]}" || true
    between_tiers
    run_tier "infrastructure" "${INFRASTRUCTURE_TESTS[@]}" || true
    between_tiers
    run_tier "recent" "${RECENT_TESTS[@]}" || true
fi

# --- unlisted: only when asked for, always last -----------------------------
if [ "$INCLUDE_UNLISTED" = true ]; then
    load_unlisted
    between_tiers
    run_tier "unlisted" "${UNLISTED_TESTS[@]}" || true
fi

# ============================================================================
# SUMMARY
# ============================================================================

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
TOTAL_PASSED=${#PASSED_SUITES[@]}
TOTAL_FAILED=${#FAILED_SUITES[@]}
TOTAL_SKIPPED=${#SKIPPED_SUITES[@]}
TOTAL=$((TOTAL_PASSED + TOTAL_FAILED + TOTAL_SKIPPED))

if [ "$TOTAL" -gt 0 ]; then
    PASS_RATE=$(( (TOTAL_PASSED * 100) / TOTAL ))
else
    PASS_RATE=0
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}FINAL RESULTS${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"
printf "${CYAN}║${NC}  %-20s %s\n" "Mode:" "$(echo "$MODE" | tr '[:lower:]' '[:upper:]')"
printf "${CYAN}║${NC}  %-20s %s\n" "Duration:" "${TOTAL_TIME}s"
printf "${CYAN}║${NC}  %-20s %s\n" "Total Suites:" "$TOTAL"
printf "${CYAN}║${NC}  %-20s ${GREEN}%s${NC}\n" "Passed:" "$TOTAL_PASSED"
printf "${CYAN}║${NC}  %-20s ${RED}%s${NC}\n" "Failed:" "$TOTAL_FAILED"
printf "${CYAN}║${NC}  %-20s ${YELLOW}%s${NC}\n" "Skipped:" "$TOTAL_SKIPPED"
printf "${CYAN}║${NC}  %-20s %s%%\n" "Pass Rate:" "$PASS_RATE"
echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"

if [ "$TOTAL" -eq 0 ]; then
    echo -e "${CYAN}║${NC}  ${YELLOW}${BOLD}NO SUITES RAN${NC} — add rows to $(basename "$MANIFEST")"
elif [ "$TOTAL_FAILED" -eq 0 ] && [ "$TOTAL_SKIPPED" -eq 0 ]; then
    echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}ALL SUITES PASSED${NC}"
elif [ "$TOTAL_FAILED" -eq 0 ]; then
    echo -e "${CYAN}║${NC}  ${GREEN}${BOLD}PASS${NC} ${YELLOW}(${TOTAL_SKIPPED} skipped — missing files)${NC}"
else
    echo -e "${CYAN}║${NC}  ${RED}${BOLD}FAILURES DETECTED${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${RED}Failed Suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "${CYAN}║${NC}    ${RED}x $suite${NC}"
    done
fi

if [ "$TOTAL_SKIPPED" -gt 0 ]; then
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}Skipped:${NC}"
    for suite in "${SKIPPED_SUITES[@]}"; do
        echo -e "${CYAN}║${NC}    ${YELLOW}- $suite${NC}"
    done
fi

echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Completed: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

[ "$TOTAL_FAILED" -gt 0 ] && exit 1
exit 0
