from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from .db import SessionLocal, Base, engine
from .models import ReferenceSet, ReferenceRole, GenomeBuild, Role
from .auth import get_current_user, require_role

router = APIRouter(prefix="/references", tags=["references"])

# --- deps ---
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# --- схемы ---
class Component(BaseModel):
    role: ReferenceRole
    uri: str = Field(min_length=1)
    md5: Optional[str] = None

class ReferenceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    genome_build: GenomeBuild
    components: List[Component]

class ReferenceUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=200)
    components: Optional[List[Component]] = None

class ReferenceOut(BaseModel):
    id: str
    name: str
    genome_build: GenomeBuild
    components: List[Component]
    is_complete: bool

# --- валидация полноты ---
REQUIRED = {ReferenceRole.FASTA, ReferenceRole.FAI, ReferenceRole.DICT, ReferenceRole.BWA_INDEX}

def _valid_md5(m: Optional[str]) -> bool:
    if not m:
        return True
    m = m.lower()
    return len(m) == 32 and all(ch in "0123456789abcdef" for ch in m)

def evaluate_complete(components: List[Component]) -> bool:
    roles = {c.role for c in components}
    if not REQUIRED.issubset(roles):
        return False
    by = {}
    for c in components:
        by.setdefault(c.role, []).append(c)

    # обязательные компоненты: uri не пустой; md5 — опционален, но если есть, должен быть валидным
    for role in (ReferenceRole.FASTA, ReferenceRole.FAI, ReferenceRole.DICT):
        if not by.get(role) or not by[role][0].uri:
            return False
        if not _valid_md5(by[role][0].md5):
            return False

    # BWA_INDEX: достаточно одного элемента с непустым uri (префикс каталога индекса или конкретный файл)
    if not by.get(ReferenceRole.BWA_INDEX) or not by[ReferenceRole.BWA_INDEX][0].uri:
        return False

    return True

# --- таблицы на старте (на всякий случай) ---
@router.on_event("startup")
def _init():
    Base.metadata.create_all(bind=engine)

# --- эндпойнты ---
@router.post(
    "",
    response_model=ReferenceOut,
    status_code=201,
    dependencies=[Depends(require_role(Role.Editor))],  # Editor/Admin (или глобальный Admin)
)
def create_ref(payload: ReferenceCreate, user=Depends(get_current_user), db: Session = Depends(get_db)):
    comps = [c.dict() for c in payload.components]
    complete = 1 if evaluate_complete(payload.components) else 0
    rs = ReferenceSet(
        name=payload.name,
        genome_build=payload.genome_build,
        components=comps,
        is_complete=complete,
    )
    db.add(rs); db.commit()
    return ReferenceOut(
        id=rs.id, name=rs.name, genome_build=rs.genome_build,
        components=payload.components, is_complete=bool(rs.is_complete)
    )

@router.get("", response_model=List[ReferenceOut])
def list_refs(db: Session = Depends(get_db), user=Depends(get_current_user)):
    rows = db.query(ReferenceSet).order_by(ReferenceSet.created_at.desc()).all()
    out = []
    for r in rows:
        out.append(ReferenceOut(
            id=r.id, name=r.name, genome_build=r.genome_build,
            components=r.components, is_complete=bool(r.is_complete)
        ))
    return out

@router.get("/{ref_id}", response_model=ReferenceOut)
def get_ref(ref_id: str, db: Session = Depends(get_db), user=Depends(get_current_user)):
    r = db.get(ReferenceSet, ref_id)
    if not r:
        raise HTTPException(status_code=404, detail="Not found")
    return ReferenceOut(
        id=r.id, name=r.name, genome_build=r.genome_build,
        components=r.components, is_complete=bool(r.is_complete)
    )

@router.patch(
    "/{ref_id}",
    response_model=ReferenceOut,
    dependencies=[Depends(require_role(Role.Editor))],
)
def update_ref(ref_id: str, payload: ReferenceUpdate, db: Session = Depends(get_db), user=Depends(get_current_user)):
    r = db.get(ReferenceSet, ref_id)
    if not r:
        raise HTTPException(status_code=404, detail="Not found")
    if payload.name:
        r.name = payload.name
    if payload.components is not None:
        comps = [c.dict() for c in payload.components]
        r.components = comps
        r.is_complete = 1 if evaluate_complete(payload.components) else 0
    db.commit()
    return ReferenceOut(
        id=r.id, name=r.name, genome_build=r.genome_build,
        components=r.components, is_complete=bool(r.is_complete)
    )

@router.delete(
    "/{ref_id}",
    dependencies=[Depends(require_role(Role.Editor))],
)
def delete_ref(ref_id: str, db: Session = Depends(get_db), user=Depends(get_current_user)):
    r = db.get(ReferenceSet, ref_id)
    if not r:
        raise HTTPException(status_code=404, detail="Not found")
    db.delete(r); db.commit()
    return {"status": "ok"}
