#!/usr/bin/env sh
# Smoke for E5.1: Workflows registry + lockfile import
set -eu

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }
need docker; need curl; need python3

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"
API="$BASE/api"

echo "▶ up stack"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "▶ wait api"
i=0; until curl -fsS "$API/healthz" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && { echo "API not ready"; exit 1; }; sleep 1; done

echo "1) login"
TOKEN="$(curl -fsS -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
echo "   token: $(echo "$TOKEN" | cut -c1-16)..."

echo "2) import nf-core/dna-seq (YAML)"
LOCK_PATH="workflows/dna-seq/lockfile.yaml"
[ -f "$LOCK_PATH" ] || { echo "No $LOCK_PATH"; exit 1; }
LOCK_YAML="$(cat "$LOCK_PATH")"
PAYLOAD="$(python3 - <<'PY'
import json,sys,os
from pathlib import Path
p=os.environ.get("LOCK_PATH","workflows/dna-seq/lockfile.yaml")
print(json.dumps({
  "name":"nf-core/dna-seq",
  #"version":"3.10.0",
  "engine":"nextflow",
  "repo":"https://github.com/nf-core/dna-seq",
  #"revision":"3.10.0",
  "git_sha":"<to-fill>",
  "lockfile_yaml": Path(p).read_text(encoding="utf-8")
}))
PY
)"
RESP="$(curl -fsS -X POST "$API/workflows/import" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$PAYLOAD")"
echo "$RESP" > .out_wf_import.json
WF_ID="$(python3 -c 'import json; print(json.load(open(".out_wf_import.json"))["id"])')"
IMAGES_CNT="$(python3 -c 'import json; print(len((json.load(open(".out_wf_import.json"))["lock"].get("containers") or [])))')"
[ "$IMAGES_CNT" -ge 1 ] || { echo "no containers in lock"; exit 1; }
echo "   ✔ imported id=$WF_ID (containers: $IMAGES_CNT)"

echo "3) list workflows"
LIST="$(curl -fsS "$API/workflows" -H "Authorization: Bearer $TOKEN")"
echo "$LIST" | tee .out_wf_list.json >/dev/null
grep -q "$WF_ID" .out_wf_list.json && echo "   ✔ workflow is listed"

echo "4) get workflow details"
DETAILS="$(curl -fsS "$API/workflows/$WF_ID" -H "Authorization: Bearer $TOKEN")"
echo "$DETAILS" | tee .out_wf_details.json >/dev/null
python3 - <<'PY'
import json
d=json.load(open(".out_wf_details.json"))
ct=d["lock"].get("containers") or []
print("   containers:", len(ct))
if ct:
    first=ct[0]
    print("   first:", {k:first.get(k) for k in ("name","image","digest")})
PY

echo ""
echo "✅ E5.1 SMOKE PASSED"
