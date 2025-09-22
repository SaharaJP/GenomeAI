import os, tempfile, hashlib
from typing import List
from fastapi import APIRouter, UploadFile, File, Form, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy.orm import Session
from .db import SessionLocal
from .models import Dataset, DatasetType, ProjectMember, Role
from .auth import get_current_user
from .s3client import client as s3client, ensure_bucket, S3_BUCKET_DATASETS

router = APIRouter(prefix="/datasets", tags=["datasets"])

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

def _detect_type(filename: str) -> DatasetType:
    fn = filename.lower()
    if fn.endswith(".fastq.gz"):
        return DatasetType.FASTQ_GZ
    if fn.endswith(".fastq"):
        return DatasetType.FASTQ
    if fn.endswith(".bam"):
        return DatasetType.BAM
    if fn.endswith(".vcf") or fn.endswith(".vcf.gz"):
        return DatasetType.VCF
    return DatasetType.OTHER

class DatasetOut(BaseModel):
    id: str
    project_id: str
    uri: str
    type: DatasetType
    size_bytes: int | None = None
    md5: str | None = None

@router.get("", response_model=List[DatasetOut])
def list_datasets(
    project_id: str = Query(...),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_view(db, user, project_id)
    rows = db.query(Dataset)\
             .filter(Dataset.project_id == project_id)\
             .order_by(Dataset.created_at.desc())\
             .all()
    return [DatasetOut(id=r.id, project_id=r.project_id, uri=r.uri, type=r.type,
                       size_bytes=r.size_bytes, md5=r.md5) for r in rows]

@router.post("/upload", response_model=DatasetOut, status_code=201)
async def upload_dataset(
    project_id: str = Form(...),
    file: UploadFile = File(...),
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_edit(db, user, project_id)

    dtype = _detect_type(file.filename)
    if dtype not in [DatasetType.FASTQ, DatasetType.FASTQ_GZ]:
        raise HTTPException(status_code=422, detail="Only FASTQ/FASTQ.GZ allowed in MVP")

    # сохраняем во временный файл, считаем md5 и размер
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        md5 = hashlib.md5()
        size = 0
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            tmp.write(chunk)
            md5.update(chunk)
            size += len(chunk)
        tmp_path = tmp.name

    key = f"{project_id}/{file.filename}"
    s3 = s3client()
    ensure_bucket()
    s3.upload_file(tmp_path, S3_BUCKET_DATASETS, key)
    os.remove(tmp_path)

    uri = f"s3://{S3_BUCKET_DATASETS}/{key}"
    ds = Dataset(project_id=project_id, uri=uri, type=dtype,
                 size_bytes=size, md5=md5.hexdigest(), owner_user_id=user["id"])
    db.add(ds)
    db.commit()
    return DatasetOut(id=ds.id, project_id=project_id, uri=uri, type=dtype,
                      size_bytes=size, md5=md5.hexdigest())

class RegisterIn(BaseModel):
    project_id: str
    uri: str
    type: DatasetType
    md5: str | None = None
    size_bytes: int | None = None

@router.post("/register", response_model=DatasetOut, status_code=201)
def register_dataset(
    payload: RegisterIn,
    user = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _require_edit(db, user, payload.project_id)
    ds = Dataset(project_id=payload.project_id, uri=payload.uri, type=payload.type,
                 size_bytes=payload.size_bytes, md5=payload.md5, owner_user_id=user["id"])
    db.add(ds)
    db.commit()
    return DatasetOut(id=ds.id, project_id=ds.project_id, uri=ds.uri, type=ds.type,
                      size_bytes=ds.size_bytes, md5=ds.md5)
