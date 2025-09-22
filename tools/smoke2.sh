#!/usr/bin/env sh
set -eu

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"
API="$BASE/api"
PROJECT_NAME="smoke-proj-$(date +%s)"
TMPDIR=".smoke_tmp"

command -v curl >/dev/null 2>&1 || { echo "curl не найден"; exit 1; }

BASE="http://localhost:8080"
API="$BASE/api"

echo "1) HEALTH CHECKS"
curl -fsS "$API/healthz" | tee .out_api.json >/dev/null
curl -fsS "$BASE/runner/healthz" | tee .out_runner.json >/dev/null
grep -q '"status":"ok"' .out_api.json
grep -q '"status":"ok"' .out_runner.json
echo "   ✔ /api/healthz & /runner/healthz OK"

echo "2) LOGIN (admin/admin123)"
LOGIN_JSON="$(curl -fsS -X POST "$API/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}')"
TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
[ -n "$TOKEN" ] || fail "No access_token in login response"
echo "   ✔ token acquired: $(printf '%s' "$TOKEN" | cut -c1-16)..."

echo "3) ME"
ME_JSON="$(curl -fsS "$API/auth/me" -H "Authorization: Bearer $TOKEN")"
printf '%s\n' "$ME_JSON" > .out_me.json
USER_ID="$(python3 -c 'import json; print(json.load(open(".out_me.json"))["id"])')"
[ -n "$USER_ID" ] || fail "Cannot extract user id from /auth/me"
echo "   ✔ /auth/me OK (user id: $USER_ID)"

echo "4) CREATE PROJECT"
CREATE_JSON="$(curl -fsS -X POST "$API/projects" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$PROJECT_NAME\"}")"
printf '%s\n' "$CREATE_JSON" > .out_project_create.json
PROJECT_ID="$(python3 -c 'import json; print(json.load(open(".out_project_create.json"))["id"])')"
[ -n "$PROJECT_ID" ] || fail "Cannot extract project id"
echo "   ✔ project created: $PROJECT_ID ($PROJECT_NAME)"

echo "5) LIST PROJECTS"
curl -fsS "$API/projects" -H "Authorization: Bearer $TOKEN" | tee .out_projects.json >/dev/null
grep -q "$PROJECT_ID" .out_projects.json && echo "   ✔ project visible in list"

echo "6) UPLOAD DATASET (FASTQ.GZ)"
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
printf '%s\n' "@r1" "ACGT" "+" "!!!!" > "$TMPDIR/sample_R1.fastq"
gzip -c "$TMPDIR/sample_R1.fastq" > "$TMPDIR/sample_R1.fastq.gz"
UPLOAD_JSON="$(curl -fsS -X POST "$API/datasets/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "project_id=$PROJECT_ID" \
  -F "file=@$TMPDIR/sample_R1.fastq.gz;type=application/gzip")"
printf '%s\n' "$UPLOAD_JSON" > .out_upload.json
echo "   ✔ uploaded: $(python3 -c 'import json;print(json.load(open(".out_upload.json"))["uri"])')"

echo "7) LIST DATASETS"
DATASETS_JSON="$(curl -fsS "$API/datasets?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN")"
printf '%s\n' "$DATASETS_JSON" > .out_datasets.json
grep -q "sample_R1.fastq.gz" .out_datasets.json && echo "   ✔ dataset appears in listing"

echo "8) REGISTER EXISTING OBJECT"
REGISTER_JSON="$(curl -fsS -X POST "$API/datasets/register" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"project_id\":\"$PROJECT_ID\",\"uri\":\"s3://datasets/$PROJECT_ID/extern.fastq.gz\",\"type\":\"FASTQ.GZ\",\"md5\":null,\"size_bytes\":12345}")"
printf '%s\n' "$REGISTER_JSON" > .out_register.json
grep -q "extern.fastq.gz" .out_register.json && echo "   ✔ external object registered"

echo "9) DATASETS AGAIN"
curl -fsS "$API/datasets?project_id=$PROJECT_ID" -H "Authorization: Bearer $TOKEN" | tee .out_datasets2.json >/dev/null
grep -q "extern.fastq.gz" .out_datasets2.json && echo "   ✔ both objects present"

echo "10) NEGATIVE (no token)"
HTTP_NOAUTH="$(curl -s -o /dev/null -w "%{http_code}" "$API/datasets?project_id=$PROJECT_ID")"
[ "$HTTP_NOAUTH" = "401" ] || fail "Expected 401 without token, got $HTTP_NOAUTH"
echo "   ✔ unauthorized access blocked (401)"

echo ""
echo "✅ ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
