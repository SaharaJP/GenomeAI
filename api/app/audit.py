from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from .db import SessionLocal
from .models import AuditLog, Role
from .auth import require_role

router = APIRouter(prefix="/audit", tags=["audit"])

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def log_event(
    db: Session,
    *,
    user_id: str | None,
    action: str,
    entity: str,
    entity_id: str | None,
    details: dict | None = None,
):
    db.add(
        AuditLog(
            user_id=user_id,
            action=action,
            entity=entity,
            entity_id=entity_id,
            details=details or {},
        )
    )
    db.commit()

@router.get("", dependencies=[Depends(require_role(Role.Admin))])
def list_audit(
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    q = db.query(AuditLog).order_by(AuditLog.id.desc()).offset(offset).limit(limit)
    return [
        {
            "id": a.id,
            "ts": a.ts.isoformat() + "Z",
            "user_id": a.user_id,
            "action": a.action,
            "entity": a.entity,
            "entity_id": a.entity_id,
            "details": a.details,
        }
        for a in q.all()
    ]

# экспортируем log_event, чтобы использовать в проектах
__all__ = ["router", "log_event"]
