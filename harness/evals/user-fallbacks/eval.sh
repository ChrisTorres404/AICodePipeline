#!/usr/bin/env bash
# user-fallbacks: the harness's other DB_USER defaults survive set -u with USER unset, even when id -un gives nothing.
set -uo pipefail
H="$PIPELINE_ROOT/harness"
FAKE="$EVAL_TMP/fakebin"; mkdir -p "$FAKE"; printf '#!/bin/sh\nexit 1\n' > "$FAKE/id"; chmod +x "$FAKE/id"
for files in lib/test-env.sh lib/verbose-test-framework.sh runners/test-cli.sh load/capture-server-metrics.sh; do
  [ -f "$H/$files" ] || { echo "FAIL setup: harness/$files is missing"; exit 1; }
done
# U1: none of the four files still falls back to a bare $USER
hits="$(grep -n -- '-$USER}' "$H/lib/test-env.sh" "$H/lib/verbose-test-framework.sh" "$H/runners/test-cli.sh" "$H/load/capture-server-metrics.sh" || true)"
[ -z "$hits" ] || { echo "FAIL U1: a DB_USER default still reads a bare \$USER"; exit 1; }
# U2: the two libraries can be sourced under set -u with USER unset and a failing id
for lib in lib/test-env.sh lib/verbose-test-framework.sh; do
  # _TEST_CONFIG_LOADED=1: test only this library's own line, not the project's (possibly older) harness/config
  out="$(cd "$H/.." && env -i PATH="$FAKE:/usr/bin:/bin" HOME="$EVAL_TMP" _TEST_CONFIG_LOADED=1 bash -c 'set -u; . "$1" >/dev/null; echo "sourced rc=$?"' _ "$H/$lib" 2>&1)"
  [ "$out" = "sourced rc=0" ] || { echo "FAIL U2: sourcing harness/$lib died with USER unset: $out"; exit 1; }
done
# U3: the metrics script gets past its DB_USER default with USER unset (a copy is run, so its
# results/ folder is written under EVAL_TMP, never inside the pipeline)
mkdir -p "$EVAL_TMP/load"; cp "$H/load/capture-server-metrics.sh" "$EVAL_TMP/load/"
out="$(cd "$EVAL_TMP" && env -i PATH="$FAKE:/usr/bin:/bin" HOME="$EVAL_TMP" bash "$EVAL_TMP/load/capture-server-metrics.sh" r1 1 2>&1 | head -20)"
case "$out" in *"[metrics] wrote "*) ;; *) echo "FAIL U3: capture-server-metrics.sh died with USER unset: $out"; exit 1;; esac
# U4: each file carries the fixed default as often as it should (U1 only sees the unbraced form)
for spec in lib/test-env.sh:1 lib/verbose-test-framework.sh:1 runners/test-cli.sh:3 load/capture-server-metrics.sh:1; do
  c="$(grep -cF -- 'DB_USER:-${USER:-$(id -un 2>/dev/null || true)}' "$H/${spec%:*}" || true)"
  [ "$c" = "${spec##*:}" ] || { echo "FAIL U4: harness/${spec%:*} carries the fixed DB_USER default $c times, not ${spec##*:}"; exit 1; }
done
exit 0
