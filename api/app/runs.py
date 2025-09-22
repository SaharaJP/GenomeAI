import json, os, urllib.request
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from .db import SessionLocal, Base, engine
from .models import Run, RunStatus, Workflow, ReferenceSet, Sample, ProjectMember, Role
from .auth import get_current_user

RUNNER_BASE = os.environ.get("RUNNER_BASE", "http://nginx/runner")  # через nginx-прокси внутри compose

router = APIRouter(prefix="/runs", tags=["runs"])

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

def _is_member(db: Session, user_id: str, project_id: str) -> ProjectMember | None:
    return db.query(ProjectMember).filter(ProjectMember.user_id==user_id, ProjectMember.project_id==project_id).first()

def _require_view(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value: return
    if not _is_member(db, user["id"], project_id):
        raise HTTPException(403, "Forbidden")

def _require_edit(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value: return
    pm = _is_member(db, user["id"], project_id)
    if not pm or pm.role not in [Role.Admin, Role.Editor]:
        raise HTTPException(403, "Forbidden")

class RunCreate(BaseModel):
    project_id: str
    workflow_id: str
    reference_set_id: str
    sample_ids: List[str] = Field(min_items=1)
    params: dict = Field(default_factory=dict)
    compute_profile: str = "local-docker"

class RunOut(BaseModel):
    id: str
    project_id: str
    workflow_id: str
    reference_set_id: str
    sample_ids: List[str]
    params: dict
    compute_profile: str
    runner_job_id: Optional[str] = None
    status: RunStatus
    artifacts: List[str]

@router.on_event("startup")
def _init():
    Base.metadata.create_all(bind=engine)

@router.post("", response_model=RunOut, status_code=201)
def create_run(payload: RunCreate, user=Depends(get_current_user), db: Session = Depends(get_db)):
    _require_edit(db, user, payload.project_id)

    wf = db.get(Workflow, payload.workflow_id)
    if not wf: raise HTTPException(404, "Workflow not found")
    ref = db.get(ReferenceSet, payload.reference_set_id)
    if not ref: raise HTTPException(404, "Reference set not found")
    if not ref.is_complete:
        raise HTTPException(422, "Reference set incomplete")

    s_rows = db.query(Sample).filter(Sample.id.in_(payload.sample_ids)).all()
    if len(s_rows) != len(payload.sample_ids):
        raise HTTPException(422, "Some sample_ids not found")
    if any(s.project_id != payload.project_id for s in s_rows):
        raise HTTPException(403, "Sample from another project")

    r = Run(
        project_id=payload.project_id,
        workflow_id=payload.workflow_id,
        reference_set_id=payload.reference_set_id,
        sample_ids=payload.sample_ids,
        params=payload.params,
        compute_profile=payload.compute_profile,
        status=RunStatus.Queued,
        created_by=user["id"]
    )
    db.add(r); db.commit()

    try:
        # если это nf-core/dna-seq — запускаем реальный пайплайн в режиме test,docker,stub
        if (wf.name or "").startswith("nf-core/dna-seq") or (wf.repo or "").endswith("nf-core/dna-seq"):
            payload = {
                "repo": (wf.repo or "https://github.com/nf-core/sarek"),
                "revision": (wf.revision or wf.version or "3.5.1"),
                "profile": "test,docker",
                "stub_run": True
            }

            if getattr(wf, "revision", None):
                rev = (wf.revision or "").strip()
                if rev:
                    payload["revision"] = rev

            req = urllib.request.Request(
                f"{RUNNER_BASE}/run/nfcore_dna_seq",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
        else:
            # fallback на контейнерный smoke (другие воркфлоу)
            req = urllib.request.Request(
                f"{RUNNER_BASE}/run/container_smoke",
                headers={"Content-Type": "application/json"},
                method="POST"
            )
        with urllib.request.urlopen(req, timeout=3600) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        r.status = RunStatus.Failed
        db.commit()
        raise HTTPException(500, f"Runner error: {e}")

    r.runner_job_id = data.get("run_id")
    r.status = RunStatus.Succeeded if data.get("status") == "Succeeded" else RunStatus.Failed
    r.artifacts = data.get("artifacts") or []
    db.commit()

    return RunOut(
        id=r.id, project_id=r.project_id, workflow_id=r.workflow_id,
        reference_set_id=r.reference_set_id, sample_ids=r.sample_ids,
        params=r.params, compute_profile=r.compute_profile,
        runner_job_id=r.runner_job_id, status=r.status, artifacts=r.artifacts
    )

@router.get("/{run_id}", response_model=RunOut)
def get_run(run_id: str, user=Depends(get_current_user), db: Session = Depends(get_db)):
    r = db.get(Run, run_id)
    if not r: raise HTTPException(404, "Not found")
    _require_view(db, user, r.project_id)
    return RunOut(
        id=r.id, project_id=r.project_id, workflow_id=r.workflow_id,
        reference_set_id=r.reference_set_id, sample_ids=r.sample_ids,
        params=r.params, compute_profile=r.compute_profile,
        runner_job_id=r.runner_job_id, status=r.status, artifacts=r.artifacts
    )

@router.get("", response_model=list[RunOut])
def list_runs(project_id: str = Query(...), user=Depends(get_current_user), db: Session = Depends(get_db)):
    _require_view(db, user, project_id)
    rows = db.query(Run).filter(Run.project_id==project_id).order_by(Run.created_at.desc()).all()
    out=[]
    for r in rows:
        out.append(RunOut(
            id=r.id, project_id=r.project_id, workflow_id=r.workflow_id,
            reference_set_id=r.reference_set_id, sample_ids=r.sample_ids,
            params=r.params, compute_profile=r.compute_profile,
            runner_job_id=r.runner_job_id, status=r.status, artifacts=r.artifacts
        ))
    return out