from typing import List, Any, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
import yaml
from yaml.parser import ParserError
from yaml.scanner import ScannerError

from .db import SessionLocal, Base, engine
from .models import Workflow, Role
from .auth import get_current_user, require_role

router = APIRouter(prefix="/workflows", tags=["workflows"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

class ImportPayload(BaseModel):
    name: str = Field(min_length=1)
    version: str = Field(min_length=1)
    engine: str = "nextflow"
    repo: Optional[str] = None
    revision: Optional[str] = None
    git_sha: Optional[str] = None
    lockfile_yaml: Optional[str] = None
    lockfile_json: Optional[dict[str, Any]] = None

class WorkflowListOut(BaseModel):
    id: str
    name: str
    version: str
    git_sha: Optional[str] = None
    images: int

class WorkflowOut(BaseModel):
    id: str
    name: str
    version: str
    engine: str
    repo: Optional[str]
    revision: Optional[str]
    git_sha: Optional[str]
    lock: dict

@router.on_event("startup")
def _init():
    Base.metadata.create_all(bind=engine)

def _parse_lock(payload: ImportPayload) -> dict:
    if payload.lockfile_json:
        return payload.lockfile_json
    if payload.lockfile_yaml:
        return yaml.safe_load(payload.lockfile_yaml)
    raise HTTPException(status_code=422, detail="Provide lockfile_json or lockfile_yaml")

def _count_images(lock: dict) -> int:
    containers = lock.get("containers") or lock.get("images") or []
    return len(containers)

@router.post(
    "/import",
    response_model=WorkflowOut,
    status_code=201,
    dependencies=[Depends(require_role(Role.Editor))],
)
def import_workflow(payload: ImportPayload, user=Depends(get_current_user), db: Session = Depends(get_db)):
    lock = _parse_lock(payload)
    if _count_images(lock) == 0:
        raise HTTPException(status_code=422, detail="Lockfile must list containers/images")
    wf = Workflow(
        name=payload.name,
        version=payload.version,
        engine=payload.engine,
        repo=payload.repo,
        revision=payload.revision,
        git_sha=payload.git_sha,
        lock=lock,
    )
    db.add(wf); db.commit()
    return WorkflowOut(
        id=wf.id, name=wf.name, version=wf.version, engine=wf.engine,
        repo=wf.repo, revision=wf.revision, git_sha=wf.git_sha, lock=wf.lock
    )

@router.get("", response_model=List[WorkflowListOut])
def list_workflows(db: Session = Depends(get_db), user=Depends(get_current_user)):
    rows = db.query(Workflow).order_by(Workflow.created_at.desc()).all()
    out = []
    for r in rows:
        images = _count_images(r.lock)
        out.append(WorkflowListOut(id=r.id, name=r.name, version=r.version, git_sha=r.git_sha, images=images))
    return out

@router.get("/{workflow_id}", response_model=WorkflowOut)
def get_workflow(workflow_id: str, db: Session = Depends(get_db), user=Depends(get_current_user)):
    wf = db.get(Workflow, workflow_id)
    if not wf:
        raise HTTPException(status_code=404, detail="Not found")
    return WorkflowOut(
        id=wf.id, name=wf.name, version=wf.version, engine=wf.engine,
        repo=wf.repo, revision=wf.revision, git_sha=wf.git_sha, lock=wf.lock
    )

def _parse_lock(payload: ImportPayload) -> dict:
    try:
        if payload.lockfile_json:
            return payload.lockfile_json
        if payload.lockfile_yaml:
            return yaml.safe_load(payload.lockfile_yaml)
        raise HTTPException(422, "Provide lockfile_json or lockfile_yaml")
    except (ParserError, ScannerError) as e:
        raise HTTPException(422, f"Invalid YAML: {e}")