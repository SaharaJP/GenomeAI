#!/usr/bin/env bash
set -euo pipefail

API="http://localhost:8080/api"
RUNNER="http://localhost:8080/runner"
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

py() { python3 - "$@"; }

line() { printf "%s\n" "== $*"; }
ok()   { printf "   %s\n" "$*"; }
fail() { printf "❌ %s\n" "$*" >&2; exit 1; }

# --- 1) Login ---
line "Login"
TOK=$(curl -fsS -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | jq -r .access_token)


# --- 2) Project ---
line "Project"
P_JSON="$TMPDIR/project.json"
PRJ_NAME="E8.2 Smoke $(date +%F) $(date +%T)"
curl -s -X POST "$API/projects" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "$(printf '{"name":"%s"}' "$PRJ_NAME")" > "$P_JSON"
PID=$(py <<'PY' "$P_JSON"
import json,sys; print(json.load(open(sys.argv[1]))["id"])
PY
)
[ -n "$PID" ] || fail "project id empty"
ok "project_id=$PID"

# --- 3) Upload tiny FASTQ pair & autopair ---
line "Samples (FASTQ pair + autopair)"
WD="$TMPDIR/fastq"; mkdir -p "$WD"
cat > "$WD"/sample_R1.fastq <<'EOF'
@r1
ACGT
+
!!!!
EOF
sed 's/@r1/@r2/' "$WD"/sample_R1.fastq > "$WD"/sample_R2.fastq
gzip -f "$WD"/sample_R1.fastq "$WD"/sample_R2.fastq

curl -s -X POST "$API/datasets/upload" -H "Authorization: Bearer $TOK" \
  -F "project_id=$PID" -F "file=@$WD/sample_R1.fastq.gz;type=application/gzip" >/dev/null
curl -s -X POST "$API/datasets/upload" -H "Authorization: Bearer $TOK" \
  -F "project_id=$PID" -F "file=@$WD/sample_R2.fastq.gz;type=application/gzip" >/dev/null

AP_JSON="$TMPDIR/autopair.json"
curl -s -X POST "$API/samples/autopair?project_id=$PID" -H "Authorization: Bearer $TOK" > "$AP_JSON" || true
SAMPLES_JSON="$TMPDIR/samples.json"
curl -s "$API/samples?project_id=$PID" -H "Authorization: Bearer $TOK" > "$SAMPLES_JSON"
SAMPLE_ID=$(py <<'PY' "$SAMPLES_JSON"
import json,sys
rows=json.load(open(sys.argv[1])); print(rows[0]["id"] if rows else "")
PY
)
[ -n "$SAMPLE_ID" ] || fail "no sample found after autopair"
ok "sample_id=$SAMPLE_ID"

# --- 4) ReferenceSet (complete) ---
line "ReferenceSet (complete any)"
REFS_JSON="$TMPDIR/refs.json"
curl -s "$API/references" -H "Authorization: Bearer $TOK" > "$REFS_JSON"
REF_ID=$(py <<'PY' "$REFS_JSON"
import json,sys
for r in json.load(open(sys.argv[1])):
    if r.get("is_complete"): print(r["id"]); break
else:
    print("")
PY
)
if [ -z "$REF_ID" ]; then
  RS_PAY="$TMPDIR/ref_create.json"
  cat > "$RS_PAY" <<'JSON'
{
  "name": "GRCh38-basic (smoke)",
  "genome_build": "GRCh38",
  "components": [
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa","md5":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"role":"FAI","uri":"s3://references/GRCh38/GRCh38.fa.fai","md5":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict","md5":"cccccccccccccccccccccccccccccccc"},
    {"role":"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
  ]
}
JSON
  REF_CREATED="$TMPDIR/ref_created.json"
  curl -s -X POST "$API/references" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    --data @"$RS_PAY" > "$REF_CREATED"
  REF_ID=$(py <<'PY' "$REF_CREATED"
import json,sys; print(json.load(open(sys.argv[1]))["id"])
PY
)
fi
[ -n "$REF_ID" ] || fail "no reference set id"
ok "reference_id=$REF_ID"

# --- 5) Workflow import: nf-core/dna-seq (NO revision) ---
line "Workflow nf-core/dna-seq (no revision)"
WF_PAY="$TMPDIR/wf_import.json"
cat > "$WF_PAY" <<'JSON'
{
  "name": "nf-core/dna-seq",
  "version": "stub",
  "engine": "nextflow",
  "repo": "https://github.com/nf-core/dna-seq",
  "lockfile_json": {
    "containers": [
      {"name":"alpine","image":"alpine:3.19","digest":"sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}
    ]
  }
}
JSON
WF_JSON="$TMPDIR/wf_created.json"
curl -s -X POST "$API/workflows/import" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  --data @"$WF_PAY" > "$WF_JSON"
WF_ID=$(py <<'PY' "$WF_JSON"
import json,sys; print(json.load(open(sys.argv[1]))["id"])
PY
)
[ -n "$WF_ID" ] || fail "workflow import failed"
ok "workflow_id=$WF_ID"

# --- 6) Runner health ---
line "Wait runner health"
for i in {1..30}; do
  if curl -fsS "$RUNNER/healthz" >/dev/null; then ok "runner ok"; break; fi
  sleep 1
  [ $i -eq 30 ] && fail "runner not healthy"
done

# --- 7) Create Run (nf-core/dna-seq test, stub) ---
line "Create Run (nf-core/dna-seq test, stub)"
RUN_PAY="$TMPDIR/run_create.json"
cat > "$RUN_PAY" <<JSON
{
  "project_id":"$PID",
  "workflow_id":"$WF_ID",
  "reference_set_id":"$REF_ID",
  "sample_ids":["$SAMPLE_ID"],
  "params":{"mode":"test"},
  "compute_profile":"local-docker"
}
JSON
RUN_JSON="$TMPDIR/run.json"
curl -s -X POST "$API/runs" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  --data @"$RUN_PAY" | tee "$RUN_JSON"

echo
py <<'PY' "$RUN_JSON"
import json,sys
d=json.load(open(sys.argv[1]))
print("status:", d.get("status"))
print("run_id:", d.get("runner_job_id"))
print("artifacts:", d.get("artifacts"))
PY

# Soft assertion (don't fail pipeline; just hint)
STATUS=$(py <<'PY' "$RUN_JSON"
import json,sys; print((json.load(open(sys.argv[1])) or {}).get("status"))
PY
)
if [ "$STATUS" != "Succeeded" ]; then
  fail "Run status=$STATUS (ожидалось Succeeded)"
fi

ok "Smoke E8.2 passed"
