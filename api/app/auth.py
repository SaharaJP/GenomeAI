import os, time, jwt
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from passlib.hash import bcrypt
from sqlalchemy.orm import Session

from .db import SessionLocal, Base, engine
from .models import User, Role

# --- конфиг ---
JWT_SECRET = os.environ.get("JWT_SECRET", "dev-secret-change-me")
JWT_ALG = "HS256"
JWT_TTL_SEC = int(os.environ.get("JWT_TTL_SEC", "1800"))  # 30 мин

router = APIRouter(prefix="/auth", tags=["auth"])
security = HTTPBearer(auto_error=False)

# --- схемы ---
class LoginIn(BaseModel):
    username: str
    password: str

class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int

# --- DB session dep ---
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# --- pw utils ---
def hash_pw(p: str) -> str:
    return bcrypt.hash(p)

def verify_pw(p: str, h: str) -> bool:
    return bcrypt.verify(p, h)

# --- JWT utils ---
def mk_token(sub: str, role: str) -> str:
    now = int(time.time())
    payload = {"sub": sub, "role": role, "iat": now, "exp": now + JWT_TTL_SEC}
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)

def decode_token(token: str):
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

# --- deps: current user & role check ---
def get_current_user(
    creds: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
):
    if not creds or creds.scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Missing bearer token")
    payload = decode_token(creds.credentials)
    user = db.get(User, payload.get("sub"))
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return {"id": user.id, "username": user.username, "role": user.role.value}

def require_role(*roles: Role):
    def dep(user = Depends(get_current_user)):
        role = user["role"]
        if role == Role.Admin.value or role in [r.value for r in roles]:
            return user
        raise HTTPException(status_code=403, detail="Forbidden")
    return dep

# --- роуты ---
@router.post("/login", response_model=TokenOut)
def login(data: LoginIn, db: Session = Depends(get_db)):
    u = db.query(User).filter(User.username == data.username).first()
    if not u or not verify_pw(data.password, u.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid credentials")
    token = mk_token(u.id, u.role.value)
    return {"access_token": token, "expires_in": JWT_TTL_SEC}

@router.post("/logout")
def logout():
    # JWT статичен; для MVP просто 200
    return {"status": "ok"}

@router.get("/me")
def me(user = Depends(get_current_user)):
    return user

# --- инициализация БД + дефолтный админ при первом старте ---
def ensure_admin():
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        if not db.query(User).first():
            admin_user = os.environ.get("ADMIN_USER", "admin")
            admin_pass = os.environ.get("ADMIN_PASS", "admin123")
            db.add(User(username=admin_user, password_hash=hash_pw(admin_pass), role=Role.Admin))
            db.commit()
    finally:
        db.close()

# экспорт для использования в main.py
__all__ = ["router", "require_role", "ensure_admin"]
