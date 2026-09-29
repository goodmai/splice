#!/usr/bin/env bash
# Usage: bench.sh <baseline|flags|jdk26> [out-dir]
# Starts an isolated localnet with the chosen JVM variant, records startup time, container count,
# steady-state memory/CPU and a read-only Scan API load run, then tears the stack down.
set -euo pipefail
VARIANT=${1:?variant: baseline|flags|jdk26}
OUT=${2:-results}
HERE=$(cd "$(dirname "$0")" && pwd)
L=$HERE/..
mkdir -p "$OUT"

FILES=(-f "$L/compose.yaml" -f "$L/resource-constraints.yaml" -f "$HERE/compose.isolate.yaml")
case $VARIANT in
  baseline) ;;
  flags) FILES+=(-f "$HERE/compose.flags.yaml") ;;
  jdk26) FILES+=(-f "$HERE/compose.jdk26.yaml") ;;
  *) echo "unknown variant $VARIANT" >&2; exit 2 ;;
esac

# DOCKER_NETWORK must have no dash: it seeds PARTY_HINT, which must match <org>-<function>-<n>.
# 0.7.5 is what the host already has pulled; override IMAGE_TAG to bench another release.
export LOCALNET_DIR=$L DOCKER_NETWORK=localnetbench TEST_PORT= IMAGE_TAG=${IMAGE_TAG:-0.7.5}
export SV_UI_PORT=14000 APP_PROVIDER_UI_PORT=13000 APP_USER_UI_PORT=12000 SWAGGER_UI_PORT=19090
export ALPHA_PROTOCOL_VERSION_ENV=${ALPHA_PROTOCOL_VERSION_ENV:-$L/env/alpha-protocol-version.env}
DC=(docker compose -p localnet-bench --env-file "$L/compose.env" --env-file "$L/env/common.env" "${FILES[@]}"
    --profile sv --profile app-provider --profile app-user)

[[ $VARIANT == jdk26 ]] && "${DC[@]}" build

cleanup() { "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
# On failure keep the service logs: they are the only evidence of why a variant did not come up.
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    for s in canton splice; do docker logs "bench-$s" > "$OUT/$VARIANT.fail.$s.log" 2>&1 || true; done
  fi
  cleanup
}
trap on_exit EXIT
cleanup

T0=$(date +%s)
"${DC[@]}" up -d --wait --wait-timeout 900
STARTUP=$(( $(date +%s) - T0 ))
sleep 120   # let JIT/heap settle before sampling

sample() { docker stats --no-stream --format '{"name":"{{.Name}}","mem_bytes":"{{.MemUsage}}","cpu":"{{.CPUPerc}}"}' \
  $("${DC[@]}" ps -q); }
sample > "$OUT/$VARIANT.idle.jsonl"
python3 "$HERE/load.py" 150 60 > "$OUT/$VARIANT.load.json"
sleep 20
sample > "$OUT/$VARIANT.after-load.jsonl"
JV=$(docker exec bench-splice java -version 2>&1 | grep -m1 'openjdk version' || true)
jq -n --arg v "$VARIANT" --arg s "$STARTUP" --arg jv "$JV" \
  --argjson n "$("${DC[@]}" ps -q | wc -l)" --slurpfile load "$OUT/$VARIANT.load.json" \
  '{variant:$v,startup_s:($s|tonumber),containers:$n,java:$jv,load:$load[0]}' > "$OUT/$VARIANT.summary.json"
cat "$OUT/$VARIANT.summary.json"
