#!/usr/bin/env sh
# Smoke for E4.1: Reference Set (GRCh38) CRUD + completeness validation
# Usage: bash smoke_references.sh
# Env: TEARDOWN=1 (optional) to docker compose down -v at the end

set -eu

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; exit 1; }; }

need docker
need curl
need python3

COMPOSE_FILE="${COMPOSE_FILE:-deploy/compose/docker-compose.yml}"
BASE="${BASE:-http://localhost:8080}"
API="$BASE/api"
TMP=".smoke_refs"
mkdir -p "$TMP"

echo "▶ Up stack"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "▶ Wait for API"
i=0; until curl -fsS "$API/healthz" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && fail "API not ready"; sleep 1; done

echo "1) LOGIN (admin/admin123)"
LOGIN_JSON="$(curl -fsS -X POST "$API/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}')"
TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
[ -n "$TOKEN" ] || { echo "Не удалось извлечь access_token из ответа: $LOGIN_JSON"; exit 1; }
echo "✔ токен получен: $(printf '%s' "$TOKEN" | cut -c1-16)..."

echo "2) CREATE ReferenceSet (COMPLETE)"
cat > "$TMP/ref_complete.json" <<'JSON'
{
  "name": "GRCh38-basic",
  "genome_build": "GRCh38",
  "components": [
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa","md5":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"role":"FAI","uri":"s3://references/GRCh38/GRCh38.fa.fai","md5":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict","md5":"cccccccccccccccccccccccccccccccc"},
    {"role":"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
  ]
}
JSON
curl -fsS -X POST "$API/references" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/ref_complete.json" | tee "$TMP/out_ref1.json" >/dev/null
REF1_ID="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref1.json"))["id"])')"
REF1_OK="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref1.json"))["is_complete"])')"
[ "$REF1_OK" = "True" -o "$REF1_OK" = "true" ] || fail "Expected is_complete=true for ref1"
echo "   ✔ created complete (id=$REF1_ID)"

echo "3) CREATE ReferenceSet (INCOMPLETE: no FAI)"
cat > "$TMP/ref_incomplete.json" <<'JSON'
{
  "name": "GRCh38-incomplete",
  "genome_build": "GRCh38",
  "components": [
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict"},
    {"role":"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
  ]
}
JSON
curl -fsS -X POST "$API/references" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/ref_incomplete.json" | tee "$TMP/out_ref2.json" >/dev/null
REF2_ID="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref2.json"))["id"])')"
REF2_OK="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref2.json"))["is_complete"])')"
[ "$REF2_OK" = "False" -o "$REF2_OK" = "false" ] || fail "Expected is_complete=false for ref2"
echo "   ✔ created incomplete (id=$REF2_ID)"

echo "4) LIST and GET"
curl -fsS "$API/references" -H "Authorization: Bearer $TOKEN" | tee "$TMP/out_list.json" >/dev/null
grep -q "$REF1_ID" "$TMP/out_list.json" || fail "ref1 not in list"
grep -q "$REF2_ID" "$TMP/out_list.json" || fail "ref2 not in list"
curl -fsS "$API/references/$REF1_ID" -H "Authorization: Bearer $TOKEN" | tee "$TMP/out_get1.json" >/dev/null
curl -fsS "$API/references/$REF2_ID" -H "Authorization: Bearer $TOKEN" | tee "$TMP/out_get2.json" >/dev/null
echo "   ✔ list/get OK"

echo "5) PATCH ref1 → make INCOMPLETE (remove BWA_INDEX)"
cat > "$TMP/ref_patch_incomplete.json" <<'JSON'
{
  "components": [
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa"},
    {"role":"FAI","uri":"s3://references/GRCh38/GRCh38.fa.fai"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict"}
  ]
}
JSON
curl -fsS -X PATCH "$API/references/$REF1_ID" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/ref_patch_incomplete.json" | tee "$TMP/out_ref1_patch.json" >/dev/null
REF1_OK2="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref1_patch.json"))["is_complete"])')"
[ "$REF1_OK2" = "False" -o "$REF1_OK2" = "false" ] || fail "Expected ref1 is_complete=false after patch"
echo "   ✔ ref1 marked incomplete"

echo "6) PATCH ref2 → make COMPLETE (add FAI)"
cat > "$TMP/ref_patch_complete.json" <<'JSON'
{
  "components": [
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa"},
    {"role":"FAI","uri":"s3://references/GRCh38/GRCh38.fa.fai"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict"},
    {"role":"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
  ]
}
JSON
curl -fsS -X PATCH "$API/references/$REF2_ID" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/ref_patch_complete.json" | tee "$TMP/out_ref2_patch.json" >/dev/null
REF2_OK2="$(python3 -c 'import json;print(json.load(open(".smoke_refs/out_ref2_patch.json"))["is_complete"])')"
[ "$REF2_OK2" = "True" -o "$REF2_OK2" = "true" ] || fail "Expected ref2 is_complete=true after patch"
echo "   ✔ ref2 marked complete"

echo "7) NEGATIVE: no token → 401 on list"
CODE="$(curl -s -o /dev/null -w "%{http_code}" "$API/references")"
[ "$CODE" = "401" ] && echo "   ✔ list requires auth (401)" || fail "expected 401, got $CODE"

echo "8) DELETE ref2"
curl -fsS -X DELETE "$API/references/$REF2_ID" -H "Authorization: Bearer $TOKEN" >/dev/null
# ensure gone
curl -s -o /dev/null -w "%{http_code}" "$API/references/$REF2_ID" -H "Authorization: Bearer $TOKEN" | grep -q '^404$' && echo "   ✔ ref2 deleted" || fail "ref2 not deleted"

echo ""
echo "✅ E4.1 SMOKE PASSED"

if [ "${TEARDOWN:-0}" = "1" ]; then
  echo "▶ Teardown"
  docker compose -f "$COMPOSE_FILE" down -v
fi
