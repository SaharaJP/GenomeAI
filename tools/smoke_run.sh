#!/usr/bin/env bash
set -euo pipefail

base="http://localhost:8080/api"

say() { printf "\n== %s\n" "$*"; }

# 0) Токен
say "Login"
TOK=$(curl -fsS -X POST "$base/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | jq -r .access_token)

hdr=(-H "Authorization: Bearer $TOK" -H 'Content-Type: application/json')

# 1) Project (если нет — создадим)
say "Project"
PID=$(curl -fsS "$base/projects" "${hdr[@]}" | jq -r '.[0].id // empty')
if [ -z "${PID:-}" ]; then
  PID=$(curl -fsS -X POST "$base/projects" "${hdr[@]}" -d '{"name":"RunSmoke"}' | jq -r .id)
fi
echo "project_id=$PID"

# 2) Dataset + Samples (если нет — создадим R1/R2 и autopair)
say "Samples"
have_sample=$(curl -fsS "$base/samples?project_id=$PID" "${hdr[@]}" | jq -r '.[0].id // empty')
if [ -z "$have_sample" ]; then
  tmpdir=$(mktemp -d)
  echo -e "@r1\nACGT\n+\n!!!!" > "$tmpdir/sample_R1.fastq"
  sed 's/@r1/@r2/' "$tmpdir/sample_R1.fastq" > "$tmpdir/sample_R2.fastq"
  gzip -f "$tmpdir/sample_R1.fastq" "$tmpdir/sample_R2.fastq"
  curl -fsS -X POST "$base/datasets/upload" -H "Authorization: Bearer $TOK" \
    -F "project_id=$PID" -F "file=@$tmpdir/sample_R1.fastq.gz;type=application/gzip" >/dev/null
  curl -fsS -X POST "$base/datasets/upload" -H "Authorization: Bearer $TOK" \
    -F "project_id=$PID" -F "file=@$tmpdir/sample_R2.fastq.gz;type=application/gzip" >/dev/null
  rm -rf "$tmpdir"
  curl -fsS -X POST "$base/samples/autopair?project_id=$PID" -H "Authorization: Bearer $TOK" >/dev/null
fi
SAMPLE_ID=$(curl -fsS "$base/samples?project_id=$PID" "${hdr[@]}" | jq -r '.[0].id')
echo "sample_id=$SAMPLE_ID"

# 3) ReferenceSet (complete)
say "ReferenceSet"
REF_ID=$(curl -fsS "$base/references" "${hdr[@]}" | jq -r '.[] | select(.is_complete==true) | .id' | head -n1)
if [ -z "${REF_ID:-}" ]; then
  cat > /tmp/ref.json <<'JSON'
{
  "name":"GRCh38-basic",
  "genome_build":"GRCh38",
  "components":[
    {"role":"FASTA","uri":"s3://references/GRCh38/GRCh38.fa"},
    {"role":"FAI","uri":"s3://references/GRCh38/GRCh38.fa.fai"},
    {"role":"DICT","uri":"s3://references/GRCh38/GRCh38.dict"},
    {"role":"BWA_INDEX","uri":"s3://references/GRCh38/bwa/GRCh38"}
  ]
}
JSON
  REF_ID=$(curl -fsS -X POST "$base/references" "${hdr[@]}" --data @/tmp/ref.json | jq -r .id)
fi
echo "reference_id=$REF_ID"

# 4) Workflow (если нет — импортим минимальный lock)
say "Workflow"
WF_ID=$(curl -fsS "$base/workflows" "${hdr[@]}" | jq -r '.[0].id // empty')
if [ -z "${WF_ID:-}" ]; then
  if [ -f "workflows/dna-seq/lockfile.yaml" ]; then
    LOCK=$(cat workflows/dna-seq/lockfile.yaml | python3 - <<'PY'
import sys, json, yaml
print(json.dumps({"lockfile_yaml": sys.stdin.read()}))
PY
)
    PAYLOAD=$(jq -n --argfile L <(echo "$LOCK") \
      --arg name "nf-core/dna-seq" --arg ver "3.10.0" --arg repo "https://github.com/nf-core/dna-seq" --arg rev "3.10.0" --arg sha "dev" '
      {name:$name,version:$ver,engine:"nextflow",repo:$repo,revision:$rev,git_sha:$sha} + $L')
  else
    # Минимальный lock JSON (контейнер обязателен)
    PAYLOAD=$(jq -n '
      {name:"nf-core/dna-seq",version:"3.10.0",engine:"nextflow",
       repo:"https://github.com/nf-core/dna-seq",revision:"3.10.0",git_sha:"dev",
       lockfile_json:{containers:[{name:"alpine",image:"alpine:3.19"}]}}')
  fi
  WF_ID=$(curl -fsS -X POST "$base/workflows/import" "${hdr[@]}" -d "$PAYLOAD" | jq -r .id)
fi
echo "workflow_id=$WF_ID"

# 5) Убедимся, что runner жив
say "Wait runner"
for i in {1..30}; do
  if curl -fsS http://localhost:8080/runner/healthz >/dev/null; then echo "  runner ok"; break; fi
  sleep 2
done

# 6) Создать Run
say "Create Run"
RUN_PAYLOAD=$(jq -n \
  --arg pid "$PID" --arg wf "$WF_ID" --arg ref "$REF_ID" --arg sid "$SAMPLE_ID" '
  {project_id:$pid, workflow_id:$wf, reference_set_id:$ref,
   sample_ids:[$sid], params:{note:"smoke"}, compute_profile:"local-docker"}')

RES=$(curl -s -X POST "$base/runs" "${hdr[@]}" -d "$RUN_PAYLOAD" || true)
echo "$RES"

status=$(echo "$RES" | jq -r '.status // empty')
echo "status: $status"