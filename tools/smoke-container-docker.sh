#!/usr/bin/env sh
# Smoke for E7.2: Nextflow with Docker (dind) — container smoke run
# - поднимает compose
# - проверяет доступность runner и Docker daemon внутри runner
# - запускает /runner/run/container_smoke
# - убеждается в статусе Succeeded и наличии колонки "container" в trace.txt

set -eu

need(){ command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }
need docker; need curl; need python3

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"
RUNNER_SVC="${RUNNER_SVC:-runner}"
DOCKER_SIDECAR_SVC="${DOCKER_SIDECAR_SVC:-docker}"

echo "▶ Up stack"
docker compose -f "$COMPOSE_FILE" up -d --build

# Показать полезные логи при любой ошибке
trap 'echo; echo "---- compose ps ----"; docker compose -f "$COMPOSE_FILE" ps;
      echo; echo "---- runner logs (last 5) ----"; docker compose -f "$COMPOSE_FILE" logs --tail=120 --no-color '"$RUNNER_SVC"' || true;
      echo; echo "---- dind logs (last 5) ----"; docker compose -f "$COMPOSE_FILE" logs --tail=120 --no-color '"$DOCKER_SIDECAR_SVC"' || true' INT TERM EXIT

echo "▶ Wait runner"
i=0; until curl -fsS "$BASE/runner/healthz" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 90 ] && { echo "runner not ready"; exit 1; }; sleep 1; done
echo "   runner ok"

echo "▶ Check Docker daemon from runner"
if ! docker compose -f "$COMPOSE_FILE" exec -T "$RUNNER_SVC" sh -lc 'docker -H "${DOCKER_HOST:-tcp://docker:2375}" version >/dev/null 2>&1'; then
  echo "❌ Docker daemon not reachable from runner. Hints:"
  echo " - ensure sidecar service 'docker:24-dind' is up and privileged"
  echo " - ensure runner env has DOCKER_HOST=tcp://docker:2375"
  exit 1
fi
echo "   docker reachable"

echo "1) Run container smoke"
RESP="$(curl -fsS -X POST "$BASE/runner/run/container_smoke")" || { echo "request failed"; exit 1; }
printf '%s\n' "$RESP" > .out_container_smoke.json

STATUS="$(python3 -c 'import json;print(json.load(open(".out_container_smoke.json"))["status"])')"
RUN_ID="$(python3 -c 'import json;print(json.load(open(".out_container_smoke.json"))["run_id"])')"
ART_CNT="$(python3 -c 'import json;print(len(json.load(open(".out_container_smoke.json"))["artifacts"]))')"

[ "$STATUS" = "Succeeded" ] || { echo "❌ status=$STATUS (expected Succeeded)"; exit 1; }
[ "$ART_CNT" -ge 3 ] || { echo "❌ artifacts count=$ART_CNT (expected ≥3)"; exit 1; }
echo "   ✔ run ok: $RUN_ID, artifacts=$ART_CNT"

echo "2) Verify trace.txt has container column"
# Скопируем trace из /work/<run_id>/trace.txt внутри runner
if ! docker compose -f "$COMPOSE_FILE" exec -T "$RUNNER_SVC" sh -lc "test -f /work/$RUN_ID/trace.txt"; then
  echo "❌ /work/$RUN_ID/trace.txt not found in runner"
  exit 1
fi
docker compose -f "$COMPOSE_FILE" exec -T "$RUNNER_SVC" sh -lc "head -n 2 /work/$RUN_ID/trace.txt" > .trace_head.txt

if grep -qi '^task_id.*container' .trace_head.txt || grep -q 'alpine:3\.19' .trace_head.txt; then
  echo "   ✔ trace contains container column / alpine:3.19"
else
  echo "❌ trace head does not show 'container' column:"
  cat .trace_head.txt
  exit 1
fi

echo ""
echo "✅ E7.2 SMOKE PASSED"

if [ "${TEARDOWN:-0}" = "1" ]; then
  echo "▶ Teardown"
  docker compose -f "$COMPOSE_FILE" down -v
fi

# снять trap на успех
trap - INT TERM EXIT
