from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from sqlalchemy import and_
from .db import SessionLocal
from .models import Project, ProjectMember, User, Role
from .auth import get_current_user, require_role
from .audit import log_event

router = APIRouter(prefix="/projects", tags=["projects"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ---- Pydantic ----
class ProjectCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)

class ProjectUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)

class ProjectOut(BaseModel):
    id: str
    name: str

class MemberAdd(BaseModel):
    username: str
    role: Role

class MemberOut(BaseModel):
    user_id: str
    username: str
    role: Role

# ---- helpers ----
def is_member(db: Session, user_id: str, project_id: str) -> ProjectMember | None:
    return (
        db.query(ProjectMember)
        .filter(and_(ProjectMember.user_id == user_id, ProjectMember.project_id == project_id))
        .first()
    )

def ensure_access(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value:
        return
    if not is_member(db, user["id"], project_id):
        raise HTTPException(status_code=403, detail="Forbidden")

def ensure_project_admin(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value:
        return
    pm = is_member(db, user["id"], project_id)
    if not pm or pm.role != Role.Admin:
        raise HTTPException(status_code=403, detail="Project admin required")

# ---- endpoints ----
@router.post("", response_model=ProjectOut, dependencies=[Depends(require_role(Role.Editor))])
def create_project(payload: ProjectCreate, user = Depends(get_current_user), db: Session = Depends(get_db)):
    p = Project(name=payload.name)
    db.add(p); db.flush()
    # создатель становится project Admin (зафиксируем всегда)
    db.add(ProjectMember(user_id=user["id"], project_id=p.id, role=Role.Admin))
    db.commit()
    log_event(db, user_id=user["id"], action="create", entity="project", entity_id=p.id, details={"name": p.name})
    return ProjectOut(id=p.id, name=p.name)

@router.get("", response_model=list[ProjectOut])
def list_projects(user = Depends(get_current_user), db: Session = Depends(get_db)):
    if user["role"] == Role.Admin.value:
        rows = db.query(Project).all()
    else:
        rows = (
            db.query(Project)
            .join(ProjectMember, Project.id == ProjectMember.project_id)
            .filter(ProjectMember.user_id == user["id"])
            .all()
        )
    return [ProjectOut(id=r.id, name=r.name) for r in rows]

@router.get("/{project_id}", response_model=ProjectOut)
def get_project(project_id: str, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_access(db, user, project_id)
    p = db.get(Project, project_id)
    if not p:
        raise HTTPException(status_code=404, detail="Not found")
    return ProjectOut(id=p.id, name=p.name)

@router.patch("/{project_id}", response_model=ProjectOut)
def update_project(project_id: str, payload: ProjectUpdate, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_project_admin(db, user, project_id)
    p = db.get(Project, project_id)
    if not p:
        raise HTTPException(status_code=404, detail="Not found")
    if payload.name:
        p.name = payload.name
    db.commit()
    log_event(
        db,
        user_id=user["id"],
        action="update",
        entity="project",
        entity_id=project_id,
        details=payload.model_dump(exclude_none=True),
    )
    return ProjectOut(id=p.id, name=p.name)

@router.delete("/{project_id}")
def delete_project(project_id: str, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_project_admin(db, user, project_id)
    p = db.get(Project, project_id)
    if not p:
        raise HTTPException(status_code=404, detail="Not found")
    db.query(ProjectMember).filter(ProjectMember.project_id == project_id).delete()
    db.delete(p); db.commit()
    log_event(db, user_id=user["id"], action="delete", entity="project", entity_id=project_id, details={})
    return {"status": "ok"}

@router.get("/{project_id}/members", response_model=list[MemberOut])
def list_members(project_id: str, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_access(db, user, project_id)
    q = (
        db.query(ProjectMember, User)
        .join(User, User.id == ProjectMember.user_id)
        .filter(ProjectMember.project_id == project_id)
        .all()
    )
    return [MemberOut(user_id=u.id, username=u.username, role=pm.role) for pm, u in q]

@router.post("/{project_id}/members")
def add_member(project_id: str, payload: MemberAdd, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_project_admin(db, user, project_id)
    u = db.query(User).filter(User.username == payload.username).first()
    if not u:
        raise HTTPException(status_code=404, detail="User not found")
    pm = is_member(db, u.id, project_id)
    if pm:
        pm.role = payload.role
    else:
        db.add(ProjectMember(user_id=u.id, project_id=project_id, role=payload.role))
    db.commit()
    log_event(
        db,
        user_id=user["id"],
        action="member_add",
        entity="project",
        entity_id=project_id,
        details={"user_id": u.id, "role": payload.role.value},
    )
    return {"status": "ok"}

@router.delete("/{project_id}/members/{user_id}")
def remove_member(project_id: str, user_id: str, user = Depends(get_current_user), db: Session = Depends(get_db)):
    ensure_project_admin(db, user, project_id)
    db.query(ProjectMember).filter(
        and_(ProjectMember.project_id == project_id, ProjectMember.user_id == user_id)
    ).delete()
    db.commit()
    log_event(
        db,
        user_id=user["id"],
        action="member_remove",
        entity="project",
        entity_id=project_id,
        details={"user_id": user_id},
    )
    return {"status": "ok"}
