import os, time, subprocess, uuid
import shutil

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from s3client import client as s3client, ensure_bucket, S3_BUCKET_RUNS
import tempfile
from pydantic import BaseModel
from fastapi import Body
from typing import Optional, List


app = FastAPI(title="GenomeAI Runner")

BASE_RUN_DIR = os.environ.get("WORK_DIR", "/nfwork")
PIPE = "/app/pipelines/hello.nf"

@app.on_event("startup")
def _init():
    os.makedirs(BASE_RUN_DIR, exist_ok=True)
    ensure_bucket()

@app.get("/healthz")
def healthz():
    return {"status":"ok"}

@app.post("/run/hello")
def run_hello():
    run_id = f"run_{int(time.time())}_{uuid.uuid4().hex[:6]}"
    run_dir = os.path.join(BASE_RUN_DIR, run_id)
    os.makedirs(run_dir, exist_ok=True)

    report = os.path.join(run_dir, "report.html")
    trace = os.path.join(run_dir, "trace.txt")
    timeline = os.path.join(run_dir, "timeline.html")

    cmd = [
        "nextflow","run", PIPE,
        "-with-report", report,
        "-with-trace", trace,
        "-with-timeline", timeline,
        "-w", os.path.join(run_dir, "work")
    ]
    try:
        proc = subprocess.run(cmd, cwd=run_dir, capture_output=True, text=True, timeout=600)
        stdout, stderr, rc = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        return JSONResponse(status_code=500, content={"run_id": run_id, "status":"Failed","error":"Timeout"})

    status = "Succeeded" if rc == 0 else "Failed"

    # upload artifacts → S3
    s3 = s3client()
    key_prefix = f"{run_id}/logs/"
    artifacts = []
    for p in (report, trace, timeline):
        if os.path.exists(p):
            key = key_prefix + os.path.basename(p)
            s3.upload_file(p, S3_BUCKET_RUNS, key)
            artifacts.append(f"s3://{S3_BUCKET_RUNS}/{key}")

    return {
        "run_id": run_id,
        "status": status,
        "artifacts": artifacts,
        "stdout_tail": stdout.splitlines()[-10:] if stdout else [],
        "stderr_tail": stderr.splitlines()[-10:] if stderr else []
    }

@app.post("/run/container_smoke")
def run_container_smoke():
    run_id = f"run_{int(time.time())}_{uuid.uuid4().hex[:6]}"
    run_dir = os.path.join(BASE_RUN_DIR, run_id)
    os.makedirs(run_dir, exist_ok=True)

    # Конфиг Nextflow: Docker + scratch + корректный process.shell (см. nf-core advisory)
    nfconf = f"""
    process.executor = 'local'
    docker.enabled   = true
    docker.runOptions = '-u 0:0'
    workDir          = '{os.path.join(run_dir, "work")}'
    """

    with open(os.path.join(run_dir, "nextflow.config"), "w") as fh:
        fh.write(nfconf)

    report   = os.path.join(run_dir, "report.html")
    trace    = os.path.join(run_dir, "trace.txt")
    timeline = os.path.join(run_dir, "timeline.html")

    cmd = [
        "nextflow", "run", "/app/pipelines/container_hello.nf",
        "-with-report", report,
        "-with-trace", trace,
        "-with-timeline", timeline,
        "-c", os.path.join(run_dir, "nextflow.config"),
        "-w", os.path.join(run_dir, "work"),
    ]
    try:
        proc = subprocess.run(cmd, cwd=run_dir, capture_output=True, text=True, timeout=900)
        stdout, stderr, rc = proc.stdout, proc.stderr, proc.returncode
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="Timeout")

    status = "Succeeded" if rc == 0 else "Failed"

    # S3 upload
    s3 = s3client()
    key_prefix = f"{run_id}/logs/"
    artifacts = []
    for pth in [report, trace, timeline]:
        if os.path.exists(pth):
            key = key_prefix + os.path.basename(pth)
            s3.upload_file(pth, S3_BUCKET_RUNS, key)
            artifacts.append(f"s3://{S3_BUCKET_RUNS}/{key}")

    # добавить хвост nextflow-лога для анализа
    nxf_log = os.path.join(run_dir, ".nextflow.log")
    log_tail = []
    if os.path.exists(nxf_log):
        with open(nxf_log, "r", encoding="utf-8", errors="ignore") as fh:
            log_tail = fh.readlines()[-12:]

    return {
        "run_id": run_id,
        "status": status,
        "artifacts": artifacts,
        "stdout_tail": stdout.splitlines()[-10:] if stdout else [],
        "stderr_tail": stderr.splitlines()[-10:] if stderr else [],
        "nextflow_log_tail": [l.rstrip("\n") for l in log_tail]
    }

class NFCoreDNASeqIn(BaseModel):
    # Ключевая правка: по умолчанию бежим sarek
    repo: str = "https://github.com/nf-core/sarek"
    revision: str | None = "3.5.1"   # или None, чтобы брать default-ветку
    profile: str = "test,docker"
    stub_run: bool = True
    docker_user: str = "0:0"
    outdir: Optional[str] = None
    extra_args: Optional[List[str]] = None
    # безопасные лимиты для маленькой машины
    max_memory: str = "3.GB"
    max_cpus: int = 2
    max_time: str = "2.h"

def _run(cmd, cwd):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=3600)
    return proc.returncode, proc.stdout, proc.stderr

@app.post("/run/nfcore_dna_seq")
def run_nfcore_dna_seq(payload: NFCoreDNASeqIn = Body(...)):
    run_id = f"run_{int(time.time())}_{uuid.uuid4().hex[:6]}"
    run_dir = os.path.join(BASE_RUN_DIR, run_id)
    os.makedirs(run_dir, exist_ok=True)

    report   = os.path.join(run_dir, "report.html")
    trace    = os.path.join(run_dir, "trace.txt")
    timeline = os.path.join(run_dir, "timeline.html")

    outdir = payload.outdir or os.path.join(run_dir, "out")
    os.makedirs(outdir, exist_ok=True)

    # nextflow.config: docker включён + принудительный user
    nfconf = (
        "process.executor = 'local'\n"
        "docker.enabled = true\n"
        f"process.containerOptions = '--user {payload.docker_user}'\n"
        f"workDir = '{os.path.join(run_dir,'work')}'\n"
    )
    with open(os.path.join(run_dir,"nextflow.config"), "w") as fh:
        fh.write(nfconf)

    # === ключевая часть: локальный clone в кеш и запуск из локального пути ===
    cache_root = os.environ.get("NFCORE_CACHE", "/opt/nfcore_cache")
    os.makedirs(cache_root, exist_ok=True)
    # имя каталога по хвосту URL (dna-seq)
    repo_name = payload.repo.rstrip("/").split("/")[-1]
    # подветка/ревизия в пути кэша (или 'default' если не указана)
    rev_label = payload.revision if payload.revision else "default"
    pipeline_dir = os.path.join(cache_root, repo_name, rev_label)
    os.makedirs(os.path.dirname(pipeline_dir), exist_ok=True)

    # если клон отсутствует — клонируем; если есть — освежим и checkout нужной ревизии
    if not os.path.isdir(os.path.join(pipeline_dir, ".git")):
        # временно клонируем, затем переключим/переместим
        tmp_dir = os.path.join(cache_root, f".tmp_{uuid.uuid4().hex[:6]}")
        os.makedirs(tmp_dir, exist_ok=True)
        rc, out, err = _run(["git","clone","--depth","1", payload.repo, tmp_dir], cwd=cache_root)
        if rc != 0:
            return JSONResponse(status_code=500, content={"run_id": run_id, "status":"Failed","error":"git clone failed","stderr_tail": err.splitlines()[-20:]})
        if payload.revision:
            rc, out, err = _run(["git","fetch","--depth","1","origin", payload.revision], cwd=tmp_dir)
            if rc == 0:
                rc2, out2, err2 = _run(["git","checkout", payload.revision], cwd=tmp_dir)
                if rc2 != 0:
                    return JSONResponse(status_code=500, content={"run_id": run_id, "status":"Failed","error":"git checkout failed","stderr_tail": (err2 or err).splitlines()[-20:]})
        os.makedirs(os.path.dirname(pipeline_dir), exist_ok=True)
        # перемещаем
        if os.path.isdir(pipeline_dir):
            shutil.rmtree(pipeline_dir, ignore_errors=True)
        shutil.move(tmp_dir, pipeline_dir)
    else:
        # refresh + optional checkout
        rc, out, err = _run(["git","fetch","--tags","--depth","1","origin"], cwd=pipeline_dir)
        if payload.revision:
            rc2, out2, err2 = _run(["git","checkout", payload.revision], cwd=pipeline_dir)
            if rc2 != 0:
                return JSONResponse(status_code=500, content={"run_id": run_id, "status":"Failed","error":"git checkout failed","stderr_tail": (err2 or err).splitlines()[-20:]})

    # теперь запускаем pipeline ИЗ ЛОКАЛЬНОГО ПУТИ, а не по URL
    cmd = [
        "nextflow","run", pipeline_dir,
        "-profile", payload.profile,
        "-with-report", report,
        "-with-trace", trace,
        "-with-timeline", timeline,
        "-c", os.path.join(run_dir,"nextflow.config"),
        "-w", os.path.join(run_dir,"work"),
        "--outdir", outdir
    ]

    if payload.revision:
        cmd.extend(["-r", payload.revision])
    if payload.stub_run:
        cmd.append("-stub-run")

    env = os.environ.copy()
    # игнорируем проверку "req > avail" — иначе даже stub-run может падать
    env["NXF_IGNORE_MAX_RESOURCES"] = "true"

    try:
        rc, stdout, stderr = _run(cmd, cwd=run_dir)
    except subprocess.TimeoutExpired:
        return JSONResponse(status_code=500, content={"run_id": run_id, "status":"Failed","error":"Timeout"})

    status = "Succeeded" if rc == 0 else "Failed"

    # загрузим артефакты в S3
    s3 = s3client()
    key_prefix = f"{run_id}/logs/"
    artifacts = []
    for pth in [report, trace, timeline]:
        if os.path.exists(pth):
            key = key_prefix + os.path.basename(pth)
            s3.upload_file(pth, S3_BUCKET_RUNS, key)
            artifacts.append(f"s3://{S3_BUCKET_RUNS}/{key}")

    return {
        "run_id": run_id,
        "status": status,
        "artifacts": artifacts,
        "stdout_tail": stdout.splitlines()[-20:] if stdout else [],
        "stderr_tail": stderr.splitlines()[-20:] if stderr else []
    }
