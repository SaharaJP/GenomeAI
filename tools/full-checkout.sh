#!/usr/bin/env bash
set -euo pipefail

### ---------- CONFIG ----------
BASE="http://localhost:8080"
RUNNER="$BASE/runner"
API="$BASE/api"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin123}"

# API endpoints (подправь при отличиях)
EP_LOGIN="$API/auth/login"
EP_PROJECTS="$API/projects"
EP_SAMPLES="$API/samples"
EP_REFERENCES="$API/references"
EP_WORKFLOWS_IMPORT="$API/workflows/import"
EP_WORKFLOWS_LIST="$API/workflows"
EP_RUNS="$API/runs"

# Runner endpoints
EP_RUNNER_HEALTH="$RUNNER/healthz"
EP_DNASEQ="$RUNNER/run/nfcore_dna_seq"  # будем вызывать только его

### ---------- UTILS ----------
REDBOLD=$'\e[1;31m'; GREEN=$'\e[32m'; CYAN=$'\e[36m'; NC=$'\e[0m'
log() { echo -e "${CYAN}== $*${NC}"; }
ok()  { echo -e "${GREEN}   $*${NC}"; }
fail(){ echo -e "${REDBOLD}❌ $*${NC}" >&2; exit 1; }

need() { command -v "$1" >/dev/null || fail "require '$1' in PATH"; }

http_post_json() { curl -fsS -H "Content-Type: application/json" -d "$2" "$1" "${@:3}"; }
http_get()       { curl -fsS "$1" "${@:2}"; }
json()           { jq -r "$1"; }
rand()           { date +%s | sha1sum 2>/dev/null | awk '{print $1}' || date +%s; }

### ---------- RUNNER PHASE ----------
wait_runner() {
  log "Wait runner health"
  for _ in {1..40}; do
    if curl -fsS "$EP_RUNNER_HEALTH" >/dev/null; then ok "runner ok"; return 0; fi
    sleep 1
  done
  fail "runner not healthy at $EP_RUNNER_HEALTH"
}

check_docker_from_runner() {
  log "Check Docker daemon from runner"
  if ! docker compose -f deploy/compose/docker-compose.yml exec -T runner \
        sh -lc 'docker -H "${DOCKER_HOST:-tcp://docker:2375}" version >/dev/null 2>&1'; then
    echo "   Docker client в runner не видит dind."
    echo "   Подсказки:"
    echo "    - сервис docker:24-dind должен быть в compose и иметь privileged: true"
    echo "    - runner должен иметь env DOCKER_HOST=tcp://docker:2375"
    echo "    - образ runner должен содержать docker-cli (apt install docker.io)"
    fail "docker daemon not reachable from runner"
  fi
  ok "docker reachable"
}

runner_smoke_sarek_via_dnaseq() {
  log "Runner smoke: call /run/nfcore_dna_seq with repo=sarek (profile: test,docker; stub-run)"
  local body='{"repo":"https://github.com/nf-core/sarek","revision":null,"profile":"test,docker","stub_run":true}'
  local resp
  resp=$(http_post_json "$EP_DNASEQ" "$body") || { echo "$resp"; fail "Runner request failed ($EP_DNASEQ)"; }

  echo "$resp" | jq -C . | sed 's/^/  /'
  local status run_id
  status=$(echo "$resp" | json '.status')
  run_id=$(echo "$resp" | json '.run_id')
  echo "status: $status"
  echo "run_id: $run_id"
  echo "artifacts:"; echo "$resp" | jq -r '.artifacts[]?' | sed 's/^/ - /' || true
  echo "--- stdout tail ---"; echo "$resp" | jq -r '.stdout_tail[]?' || true
  echo "--- stderr tail ---"; echo "$resp" | jq -r '.stderr_tail[]?' || true
  [[ "$status" == "Succeeded" ]] || fail "runner smoke failed (status=$status)"
  ok "runner smoke OK"
}

### ---------- API PHASE ----------
login() {
  log "Login"
  local resp token
  resp=$(http_post_json "$EP_LOGIN" "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}") || {
    echo "$resp"; fail "auth failed at $EP_LOGIN"
  }
  token=$(echo "$resp" | json '.access_token')
  [[ -n "$token" && "$token" != "null" ]] || fail "no token in login response"
  echo "$token"
}
api_get() { local tok="$1"; shift; curl -fsS -H "Authorization: Bearer $tok" "$@"; }
api_post_json() { local tok="$1"; local url="$2"; local body="$3"; curl -fsS -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "$body" "$url"; }

ensure_project() {
  local token="$1"
  log "Project (create new)"
  local name="smoke-proj-$(rand | cut -c1-8)"
  local resp pid
  resp=$(api_post_json "$token" "$EP_PROJECTS" "{\"name\":\"$name\"}") || { echo "$resp"; fail "create project failed ($EP_PROJECTS)"; }
  pid=$(echo "$resp" | json '.id')
  echo "project_id=$pid"
  [[ -n "$pid" && "$pid" != "null" ]] || fail "no project id"
  echo "$pid"
}

ensure_sample() {
  local token="$1"; local pid="$2"
  log "Samples (ensure one exists)"
  local resp sid
  resp=$(api_get "$token" "$EP_SAMPLES?project_id=$pid") || true
  sid=$(echo "$resp" | jq -r '.[0].id? // empty') || true
  if [[ -n "$sid" ]]; then echo "sample_id=$sid"; echo "$sid"; return 0; fi

  # fallback: простой create (адаптируй под свой API при необходимости)
  local sname="smoke-sample-$(rand | cut -c1-6)"
  resp=$(api_post_json "$token" "$EP_SAMPLES" "{\"project_id\":\"$pid\",\"name\":\"$sname\",\"meta\":{}}") || true
  sid=$(echo "$resp" | json '.id' || true)
  [[ -n "$sid" && "$sid" != "null" ]] || fail "no sample id (проверь $EP_SAMPLES)"
  echo "sample_id=$sid"
  echo "$sid"
}

ensure_reference() {
  local token="$1"
  log "ReferenceSet (complete or pick existing)"
  # Попробуем создать…
  local create
  create=$(jq -n '{
    name: "GRCh38-basic-smoke",
    genome_build: "GRCh38",
    components: [
      {role:"FASTA", "uri":"s3://references/GRCh38/GRCh38.fa",    "md5":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {role:"FAI",   "uri":"s3://references/GRCh38/GRCh38.fa.fai","md5":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
      {role:"DICT",  "uri":"s3://references/GRCh38/GRCh38.dict",  "md5":"cccccccccccccccccccccccccccccccc"},
      {role:"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
    ] }')
  local resp rid complete
  if resp=$(api_post_json "$token" "$EP_REFERENCES" "$create"); then
    rid=$(echo "$resp" | json '.id'); complete=$(echo "$resp" | json '.is_complete')
    echo "reference_id=$rid (is_complete=$complete)"
    [[ "$complete" == "true" || "$complete" == "True" ]] || fail "ReferenceSet not complete"
    echo "$rid"; return 0
  fi

  # …или взять первый complete из списка
  resp=$(api_get "$token" "$EP_REFERENCES") || fail "list references failed ($EP_REFERENCES)"
  rid=$(echo "$resp" | jq -r '[.[] | select(.is_complete==true or .is_complete==True)][0].id // empty')
  [[ -n "$rid" ]] || fail "no complete ReferenceSet found"
  echo "reference_id=$rid (picked existing)"
  echo "$rid"
}

ensure_workflow_sarek_labelled_dnaseq() {
  local token="$1"
  log "Workflow import (label as nf-core/dna-seq; repo → sarek)"
  local lockfile
  lockfile=$(jq -n '{
    workflow: { name: "nf-core/dna-seq", repo: "https://github.com/nf-core/sarek" },
    containers: [ {name:"bash", image:"bash:5.2", digest:"sha256:deadbeef"} ]
  }')
  local body
  body=$(jq -n --argjson lock "$lockfile" '{
    name: "nf-core/dna-seq",
    version: "main",
    engine: "nextflow",
    repo: "https://github.com/nf-core/sarek",
    revision: null,
    git_sha: null,
    lockfile_json: $lock
  }')
  local resp wid
  resp=$(api_post_json "$token" "$EP_WORKFLOWS_IMPORT" "$body") || { echo "$resp"; fail "workflow import failed ($EP_WORKFLOWS_IMPORT)"; }
  wid=$(echo "$resp" | json '.id')
  echo "workflow_id=$wid"
  [[ -n "$wid" && "$wid" != "null" ]] || fail "no workflow id"
  echo "$wid"
}

create_run_dnaseq_stub() {
  local token="$1"; local pid="$2"; local wid="$3"; local refid="$4"; local sid="$5"
  log "Create Run (nf-core/dna-seq test, stub via Runner)"
  local body
  body=$(jq -n --arg pid "$pid" --arg wid "$wid" --arg ref "$refid" --arg sid "$sid" '{
    project_id: $pid,
    workflow_id: $wid,
    reference_set_id: $ref,
    sample_ids: [$sid],
    params: {mode:"test"},
    compute_profile: "local-docker"
  }')
  local resp status rid rrun
  resp=$(api_post_json "$token" "$EP_RUNS" "$body") || { echo "$resp"; fail "POST /runs failed ($EP_RUNS)"; }
  echo "$resp" | jq -C . | sed 's/^/  /'
  status=$(echo "$resp" | json '.status')
  rid=$(echo "$resp" | json '.id')
  rrun=$(echo "$resp" | json '.runner_job_id')
  echo "status: $status | run_id: $rrun | api_id: $rid"
  echo "artifacts:"; echo "$resp" | jq -r '.artifacts[]?' | sed 's/^/ - /' || true
  [[ "$status" == "Succeeded" ]] || fail "Run status=$status (ожидалось Succeeded)"
  ok "API run OK"
}

### ---------- MAIN ----------
main() {
  need curl; need jq

  # Runner-only smoke
  wait_runner
  check_docker_from_runner
  runner_smoke_sarek_via_dnaseq

  # API flow
  local token pid sid refid wid
  token=$(login)
  pid=$(ensure_project "$token")
  sid=$(ensure_sample "$token" "$pid")
  refid=$(ensure_reference "$token")
  wid=$(ensure_workflow_sarek_labelled_dnaseq "$token")
  create_run_dnaseq_stub "$token" "$pid" "$wid" "$refid" "$sid"

  echo
  ok "FULL SMOKE PASSED"
}

main "$@"
