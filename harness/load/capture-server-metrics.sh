#!/usr/bin/env bash
# ============================================================================
# Sample server-side metrics during a load run. Run it alongside k6.
# ============================================================================
#   ./capture-server-metrics.sh <run-id> [duration-seconds]
#
# Writes results/<run-id>/server-metrics.csv, one row every INTERVAL seconds.
# Client-side latency alone never names a bottleneck; this is the other half of
# the evidence — cross-reference a timestamp here against the k6 summary.
#
# Every source is optional and simply reports NA when unavailable:
#   API_CONTAINER / DB_CONTAINER  container names sampled with `docker stats`
#   DB_NAME (+ DB_HOST/DB_PORT/DB_USER)  Postgres connection counts via psql
#   INTERVAL                      seconds between samples (default 5)
# ============================================================================
set -uo pipefail

RUN_ID="${1:?run-id}"
DUR="${2:-600}"
INTERVAL="${INTERVAL:-5}"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-${USER:-$(id -un 2>/dev/null || true)}}"
DB_NAME="${DB_NAME:-}"
export PGPASSWORD="${PGPASSWORD:-${DB_PASS:-}}"

API_CONTAINER="${API_CONTAINER:-}"
DB_CONTAINER="${DB_CONTAINER:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results/$RUN_ID"
mkdir -p "$OUT"
CSV="$OUT/server-metrics.csv"
echo "ts,active_conns,idle_conns,api_cpu_pct,api_mem,db_cpu_pct,db_mem" > "$CSV"

have_db() { [ -n "$DB_NAME" ] && command -v psql > /dev/null 2>&1; }
have_docker() { command -v docker > /dev/null 2>&1; }

if ! have_db; then
  echo "[metrics] no database configured (DB_NAME) — connection columns will be NA"
fi
if ! have_docker || { [ -z "$API_CONTAINER" ] && [ -z "$DB_CONTAINER" ]; }; then
  echo "[metrics] no containers configured (API_CONTAINER/DB_CONTAINER) — cpu/mem columns will be NA"
fi

echo "[metrics] sampling every ${INTERVAL}s for ${DUR}s -> $CSV"

end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%s)
  active=NA
  idle=NA

  if have_db; then
    active=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
      "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB_NAME' AND state='active';" 2>/dev/null || echo NA)
    idle=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
      "SELECT count(*) FROM pg_stat_activity WHERE datname='$DB_NAME' AND state='idle';" 2>/dev/null || echo NA)
  fi

  api_cpu=NA; api_mem=NA; db_cpu=NA; db_mem=NA
  if have_docker; then
    stats=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' 2>/dev/null || true)
    if [ -n "$API_CONTAINER" ]; then
      row=$(echo "$stats" | grep -F "$API_CONTAINER" | head -1 || true)
      [ -n "$row" ] && { api_cpu=$(echo "$row" | awk '{print $2}'); api_mem=$(echo "$row" | awk '{print $3}'); }
    fi
    if [ -n "$DB_CONTAINER" ]; then
      row=$(echo "$stats" | grep -F "$DB_CONTAINER" | head -1 || true)
      [ -n "$row" ] && { db_cpu=$(echo "$row" | awk '{print $2}'); db_mem=$(echo "$row" | awk '{print $3}'); }
    fi
  fi

  echo "$ts,$active,$idle,$api_cpu,$api_mem,$db_cpu,$db_mem" >> "$CSV"
  sleep "$INTERVAL"
done

echo "[metrics] wrote $CSV"
