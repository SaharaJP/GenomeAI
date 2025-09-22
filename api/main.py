from fastapi import FastAPI, Depends
from app.auth import router as auth_router, ensure_admin, require_role
from app.models import Role
from app.projects import router as projects_router
from app.audit import router as audit_router
from app.datasets import router as datasets_router
from app.s3client import ensure_bucket
from app.samples import router as samples_router
from app.references import router as references_router
from app.workflows import router as workflows_router



app = FastAPI(title="GenomeAI API")
from app.runs import router as runs_router

@app.on_event("startup")
def _init():
    ensure_admin()
    ensure_bucket()

@app.get("/healthz")
def healthz():
    return {"status":"ok"}

# auth
app.include_router(auth_router)
# projects & audit
app.include_router(projects_router)
app.include_router(audit_router)
# datasets
app.include_router(datasets_router)
#samples
app.include_router(samples_router)
#references
app.include_router(references_router)
#workflows
app.include_router(workflows_router)

app.include_router(runs_router)
