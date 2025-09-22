import csv, io, re
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Query, Response, Body
from pydantic import BaseModel
from sqlalchemy.orm import Session

from .db import SessionLocal
from .models import Sample, Dataset, DatasetType, ProjectMember, Role
from .auth import get_current_user

router = APIRouter(prefix="/samples", tags=["samples"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def _is_member(db: Session, user_id: str, project_id: str) -> bool:
    return db.query(ProjectMember).filter(
        ProjectMember.user_id == user_id,
        ProjectMember.project_id == project_id
    ).first() is not None

def _require_view(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value:
        return
    if not _is_member(db, user["id"], project_id):
        raise HTTPException(status_code=403, detail="Forbidden")

def _require_edit(db: Session, user: dict, project_id: str):
    if user["role"] == Role.Admin.value:
        return
    pm = db.query(ProjectMember).filter(
        ProjectMember.user_id == user["id"],
        ProjectMember.project_id == project_id
    ).first()
    if not pm or pm.role not in [Role.Admin, Role.Editor]:
        raise HTTPException(status_code=403, detail="Forbidden")

# Поддерживаемые шаблоны имён:
# *_R1.fastq.gz, *_R2.fastq.gz, *R1_001.fastq.gz,
# *_1.fastq.gz, *_2.fastq.gz, *.read1.*, *.read2.*
PATTERN = re.compile(
    r"""^(?P<stem>.*?)
        (?:
          (?:[_\.]?R(?P<read>[12]))            # _R1 / .R1
          |(?:[_\.-]?(?P<read_alt>[12]))       # _1 / -2 / .2
          |(?:[_\.]?read(?P<read_word>[12]))   # .read1
        )
        (?:[_\.]?\d{3})?                       # опц. _001
        \.fastq(?:\.gz)?$                      # расширение
    """, re.IGNORECASE | re.VERBOSE
)

def _read_from_match(m):
    return m.group("read") or m.group("read_alt") or m.group("read_word")

class SampleOut(BaseModel):
    id: str
    project_id: str
    name: str
    r1_dataset_id: str
    r2_dataset_id: str
    r1_uri: str
    r2_uri: str

class AutopairResult(BaseModel):
    created: List[SampleOut]
    updated: List[SampleOut]
    orphans: List[str]  # dataset ids без пары/совпадения шаблона

@router.get("", response_model=List[SampleOut])
def list_samples(
    project_id: str = Query(...),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_view(db, user, project_id)
    rows = db.query(Sample).filter(Sample.project_id == project_id).all()
    id2uri = {d.id: d.uri for d in db.query(Dataset).filter(Dataset.project_id == project_id).all()}
    out = []
    for s in rows:
        out.append(SampleOut(
            id=s.id, project_id=s.project_id, name=s.name,
            r1_dataset_id=s.r1_dataset_id, r2_dataset_id=s.r2_dataset_id,
            r1_uri=id2uri.get(s.r1_dataset_id, ""), r2_uri=id2uri.get(s.r2_dataset_id, "")
        ))
    return out

@router.post("/autopair", response_model=AutopairResult)
def autopair(
    project_id: str = Query(...),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_edit(db, user, project_id)
    fastqs = db.query(Dataset).filter(
        Dataset.project_id == project_id,
        Dataset.type.in_([DatasetType.FASTQ, DatasetType.FASTQ_GZ])
    ).all()

    stems = {}
    orphans: List[str] = []

    for d in fastqs:
        fn = d.uri.split("/")[-1]
        m = PATTERN.match(fn)
        if not m:
            orphans.append(d.id)
            continue
        stem = m.group("stem")
        read = _read_from_match(m)
        bucket = stems.setdefault(stem, {"R1": None, "R2": None})
        if read == "1":
            bucket["R1"] = d
        elif read == "2":
            bucket["R2"] = d
        else:
            orphans.append(d.id)

    created, updated = [], []
    for stem, pair in stems.items():
        r1, r2 = pair["R1"], pair["R2"]
        if not (r1 and r2):
            if r1: orphans.append(r1.id)
            if r2: orphans.append(r2.id)
            continue
        s = db.query(Sample).filter(
            Sample.project_id == project_id,
            Sample.name == stem
        ).first()
        if s:
            changed = (s.r1_dataset_id != r1.id) or (s.r2_dataset_id != r2.id)
            s.r1_dataset_id, s.r2_dataset_id = r1.id, r2.id
            db.commit()
            if changed:
                updated.append(s)
        else:
            s = Sample(project_id=project_id, name=stem, r1_dataset_id=r1.id, r2_dataset_id=r2.id)
            db.add(s); db.commit()
            created.append(s)

    id2uri = {d.id: d.uri for d in fastqs}
    def to_out(s: Sample) -> SampleOut:
        return SampleOut(
            id=s.id, project_id=s.project_id, name=s.name,
            r1_dataset_id=s.r1_dataset_id, r2_dataset_id=s.r2_dataset_id,
            r1_uri=id2uri.get(s.r1_dataset_id, ""), r2_uri=id2uri.get(s.r2_dataset_id, "")
        )

    return AutopairResult(
        created=[to_out(x) for x in created],
        updated=[to_out(x) for x in updated],
        orphans=orphans
    )

# --- экспорт CSV: sample,r1_uri,r2_uri ---
@router.get("/export.csv")
def export_csv(
    project_id: str = Query(...),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_view(db, user, project_id)
    rows = list_samples(project_id, user, db)
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["sample", "r1_uri", "r2_uri"])
    for s in rows:
        w.writerow([s.name, s.r1_uri, s.r2_uri])
    return Response(
        content=buf.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="samples_{project_id}.csv"'},
    )

# --- импорт CSV/JSON (апсерты) ---
class SampleIn(BaseModel):
    project_id: str
    name: str
    r1_uri: str
    r2_uri: str

@router.post("/import")
async def import_samples(
    project_id: str = Query(...),
    file: UploadFile | None = File(None),
    items: Optional[List[SampleIn]] = Body(None),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_edit(db, user, project_id)

    to_process = []
    if file:
        data = (await file.read()).decode("utf-8", "ignore")
        rdr = csv.DictReader(io.StringIO(data))
        for row in rdr:
            to_process.append({
                "name": row["sample"],
                "r1_uri": row["r1_uri"],
                "r2_uri": row["r2_uri"],
            })
    elif items is not None:
        for it in items:
            if it.project_id != project_id:
                raise HTTPException(status_code=422, detail="Mismatched project_id in payload")
        to_process = [{"name": it.name, "r1_uri": it.r1_uri, "r2_uri": it.r2_uri} for it in items]
    else:
        raise HTTPException(status_code=400, detail="Provide CSV file or JSON body")

    dmap = {d.uri: d for d in db.query(Dataset).filter(Dataset.project_id == project_id).all()}

    created = updated = 0
    for it in to_process:
        r1 = dmap.get(it["r1_uri"])
        r2 = dmap.get(it["r2_uri"])
        if not r1 or not r2:
            raise HTTPException(status_code=422, detail=f"Dataset(s) not found by uri: {it}")
        if r1.type not in [DatasetType.FASTQ, DatasetType.FASTQ_GZ] or r2.type not in [DatasetType.FASTQ, DatasetType.FASTQ_GZ]:
            raise HTTPException(status_code=422, detail="Only FASTQ/FASTQ.GZ supported")
        s = db.query(Sample).filter(Sample.project_id == project_id, Sample.name == it["name"]).first()
        if s:
            s.r1_dataset_id, s.r2_dataset_id = r1.id, r2.id
            updated += 1
        else:
            db.add(Sample(project_id=project_id, name=it["name"], r1_dataset_id=r1.id, r2_dataset_id=r2.id))
            created += 1
        db.commit()

    return {"created": created, "updated": updated}
