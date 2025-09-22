#!/usr/bin/env sh
# Smoke for E3.3: pairing R1/R2 and Sample Sheet (CSV export/import)
set -eu

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }
need curl; need python3

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"
API="$BASE/api"

# 0) ensure stack is up
docker compose -f "$COMPOSE_FILE" up -d --build

echo "1) wait for API"
i=0; until curl -fsS "$API/healthz" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && { echo "API not ready"; exit 1; }; sleep 1; done
echo "   ok"

echo "2) login"
LOGIN_JSON="$(curl -fsS -X POST "$API/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}')"
TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
[ -n "$TOKEN" ] || { echo "Не удалось извлечь access_token из ответа: $LOGIN_JSON"; exit 1; }
echo "✔ токен получен: $(printf '%s' "$TOKEN" | cut -c1-16)..."

echo "3) create project"
PNAME="Test Project $(date +%s)"
CREATE_JSON="$(curl -fsS -X POST "$API/projects" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$PNAME\"}")"
printf '%s\n' "$CREATE_JSON" > .out_project_create.json
PROJECT_ID="$(python3 -c 'import json; print(json.load(open(".out_project_create.json"))["id"])')"
[ -n "$PROJECT_ID" ] || { echo "Не удалось извлечь project id: $CREATE_JSON"; exit 1; }
echo "✔ проект создан (id: $PROJECT_ID, name: $PNAME)"

echo "4) prepare R1/R2 and upload"
TMP=".smoke_samples"; rm -rf "$TMP"; mkdir -p "$TMP"
printf '%s\n' "@r1" "ACGT" "+" "!!!!" > "$TMP/sample_R1.fastq"
sed 's/r1/r2/' "$TMP/sample_R1.fastq" > "$TMP/sample_R2.fastq"
gzip -f "$TMP/sample_R1.fastq"; gzip -f "$TMP/sample_R2.fastq"

curl -fsS -X POST "$API/datasets/upload" -H "Authorization: Bearer $TOKEN" \
  -F "project_id=$PROJECT_ID" -F "file=@$TMP/sample_R1.fastq.gz;type=application/gzip" >/dev/null
curl -fsS -X POST "$API/datasets/upload" -H "Authorization: Bearer $TOKEN" \
  -F "project_id=$PROJECT_ID" -F "file=@$TMP/sample_R2.fastq.gz;type=application/gzip" >/dev/null
echo "   uploaded R1/R2"

echo "5) autopair"
AUTO="$(curl -fsS -X POST "$API/samples/autopair?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN")"
printf '%s\n' "$AUTO" > .out_autopair.json
CREATED_CNT="$(python3 -c 'import json;print(len(json.load(open(".out_autopair.json"))["created"]))')"
[ "$CREATED_CNT" -ge 1 ] || { echo "no samples created by autopair"; exit 1; }
echo "   created: $CREATED_CNT"

echo "6) list samples"
LIST="$(curl -fsS "$API/samples?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN")"
printf '%s\n' "$LIST" > .out_samples.json
python3 - <<'PY'
import json
d=json.load(open(".out_samples.json"))
assert len(d)>=1, "no samples listed"
s=d[0]
assert "r1_uri" in s and "r2_uri" in s, "missing uris"
print("   sample:", s["name"])
print("   r1_uri:", s["r1_uri"])
print("   r2_uri:", s["r2_uri"])
PY

echo "7) export CSV (head)"
curl -fsS "$API/samples/export.csv?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN" | tee .out_samples.csv | head -n 3 >/dev/null
head -n1 .out_samples.csv | grep -q 'sample,r1_uri,r2_uri' && echo "   csv header ok"

echo "8) import (CSV upsert) — rename first sample"
FIRST_NAME="$(python3 -c 'import json;print(json.load(open(".out_samples.json"))[0]["name"])')"
R1_URI="$(python3 -c 'import json;print(json.load(open(".out_samples.json"))[0]["r1_uri"])')"
R2_URI="$(python3 -c 'import json;print(json.load(open(".out_samples.json"))[0]["r2_uri"])')"
echo "sample,r1_uri,r2_uri" > .import.csv
echo "${FIRST_NAME}_renamed,${R1_URI},${R2_URI}" >> .import.csv
curl -fsS -X POST "$API/samples/import?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN" -F "file=@.import.csv" | tee .out_import.json >/dev/null
curl -fsS "$API/samples?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN" | tee .out_samples2.json >/dev/null
grep -q "${FIRST_NAME}_renamed" .out_samples2.json && echo "   import upsert ok"

echo ""
echo "✅ E3.3 SMOKE PASSED"
