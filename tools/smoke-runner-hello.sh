#!/usr/bin/env sh
# Smoke for E7.1: Runner hello + reports to S3
set -eu

need(){ command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }
need docker; need curl; need python3

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"


echo "▶ wait runner"
i=0; until curl -fsS "$BASE/runner/healthz" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 90 ] && { echo "runner not ready"; exit 1; }; sleep 1; done
echo "   runner ok"

echo "1) run hello"
RESP="$(curl -fsS -X POST "$BASE/runner/run/hello")" || { echo "run failed"; exit 1; }
echo "$RESP" | tee .out_runner_hello.json >/dev/null

STATUS="$(python3 -c 'import json;print(json.load(open(".out_runner_hello.json"))["status"])')"
RUN_ID="$(python3 -c 'import json;print(json.load(open(".out_runner_hello.json"))["run_id"])')"
ART_CNT="$(python3 -c 'import json;print(len(json.load(open(".out_runner_hello.json"))["artifacts"]))')"

[ "$STATUS" = "Succeeded" ] || { echo "status=$STATUS (expected Succeeded)"; exit 1; }
[ "$ART_CNT" -ge 3 ] && echo "   ✔ artifacts uploaded ($ART_CNT), run_id=$RUN_ID" || { echo "artifacts count=$ART_CNT"; exit 1; }

echo ""
echo "✅ E7.1 SMOKE PASSED"
