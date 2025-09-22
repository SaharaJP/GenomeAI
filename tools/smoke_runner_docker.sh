#!/usr/bin/env bash
set -euo pipefail

compose="deploy/compose/docker-compose.yml"

say()  { printf "%s\n" "$*"; }
ok()   { printf "   ✔ %s\n" "$*"; }
fail() { printf "   ❌ %s\n" "$*" >&2; exit 1; }

# 0) ensure up
docker compose -f "$compose" up -d --build >/dev/null

say "▶ Check Docker daemon from runner"
docker compose -f "$compose" exec -T runner sh -lc 'docker -H "${DOCKER_HOST:-tcp://docker:2375}" version >/dev/null' \
  && ok "docker reachable" || fail "Docker daemon not reachable from runner"

say "▶ Check shared volume nf-work between runner and dind"
# пишем пробный файл в /work внутри runner
docker compose -f "$compose" exec -T runner sh -lc 'echo smoke-probe > /work/_probe.txt && chmod 644 /work/_probe.txt'
# читаем его из контейнера, запущенного на dind
docker compose -f "$compose" exec -T runner sh -lc \
  'docker -H "${DOCKER_HOST:-tcp://docker:2375}" run --rm -v /work:/work ubuntu:22.04 bash -lc "cat /work/_probe.txt"' \
  | grep -q smoke-probe && ok "shared volume content visible inside job container" || fail "shared volume not visible in job container"

say "▶ Run container_smoke"
json=$(curl -fsS -X POST http://localhost:8080/runner/run/container_smoke)
echo "$json" | jq -r '.status' >/dev/null 2>&1 || { echo "$json"; fail "invalid JSON"; }

status=$(echo "$json" | jq -r '.status')
run_id=$(echo "$json" | jq -r '.run_id')
artifacts=$(echo "$json" | jq -r '.artifacts[]?' | tr '\n' ' ')
echo "status: $status"
echo "run_id: $run_id"
echo "artifacts: $artifacts"

[ "$status" = "Succeeded" ] || {
  echo "--- nextflow log tail ---"
  echo "$json" | jq -r '.nextflow_log_tail[]?' || true
  echo "--- stderr tail ---"
  echo "$json" | jq -r '.stderr_tail[]?' || true
  fail "container_smoke failed"
}

ok "container_smoke Succeeded"

# Доп.проверка: колонка 'container' в trace.txt
if echo "$artifacts" | grep -q 'trace.txt'; then
  # скачиваем из MinIO через API
  trace_key=$(echo "$artifacts" | tr ' ' '\n' | grep 'trace.txt' | sed 's#^s3://runs/##')
  curl -fsS "http://minio:9000/runs/${trace_key}" -o /tmp/trace.txt 2>/dev/null || true
  if [ -s /tmp/trace.txt ]; then
    head -n1 /tmp/trace.txt | grep -qi container && ok "trace.txt has 'container' column"
  fi
fi

say "All good ✔"
