from datetime import datetime
from sqlalchemy import Column, String, DateTime, Enum, ForeignKey, Integer, JSON, BigInteger
from sqlalchemy.orm import relationship
import uuid, enum
from sqlalchemy import JSON as SAJSON

from .db import Base

class Role(str, enum.Enum):
    Admin = "Admin"
    Editor = "Editor"
    Viewer = "Viewer"

def uuid4() -> str:
    return str(uuid.uuid4())

class User(Base):
    __tablename__ = "users"
    id = Column(String, primary_key=True, default=uuid4)
    username = Column(String, unique=True, nullable=False, index=True)
    password_hash = Column(String, nullable=False)
    role = Column(Enum(Role), default=Role.Viewer, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

class Project(Base):
    __tablename__ = "projects"
    id = Column(String, primary_key=True, default=uuid4)
    name = Column(String, nullable=False)

class ProjectMember(Base):
    __tablename__ = "project_members"
    user_id = Column(String, ForeignKey("users.id"), primary_key=True)
    project_id = Column(String, ForeignKey("projects.id"), primary_key=True)
    role = Column(Enum(Role), nullable=False)
    # user = relationship("User")
    # project = relationship("Project")

class AuditLog(Base):
    __tablename__ = "audit_logs"
    id = Column(Integer, primary_key=True, autoincrement=True)
    ts = Column(DateTime, default=datetime.utcnow, index=True)
    user_id = Column(String, nullable=True)
    action = Column(String, nullable=False)
    entity = Column(String, nullable=False)      # e.g., "project", "member", "dataset"
    entity_id = Column(String, nullable=True)
    details = Column(JSON, nullable=True)

class DatasetType(str, enum.Enum):
    FASTQ = "FASTQ"
    FASTQ_GZ = "FASTQ.GZ"
    BAM = "BAM"
    VCF = "VCF"
    OTHER = "OTHER"

class Dataset(Base):
    __tablename__ = "datasets"
    id = Column(String, primary_key=True, default=uuid4)
    project_id = Column(String, ForeignKey("projects.id"), index=True, nullable=False)
    uri = Column(String, nullable=False)        # s3://datasets/<project>/<file> или внешний URI
    type = Column(Enum(DatasetType), nullable=False)
    size_bytes = Column(BigInteger, nullable=True)
    md5 = Column(String, nullable=True)         # 32 hex
    owner_user_id = Column(String, ForeignKey("users.id"), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

class Sample(Base):
    __tablename__ = "samples"
    id = Column(String, primary_key=True, default=uuid4)
    project_id = Column(String, ForeignKey("projects.id"), index=True, nullable=False)
    name = Column(String, index=True, nullable=False)
    r1_dataset_id = Column(String, ForeignKey("datasets.id"), nullable=False)
    r2_dataset_id = Column(String, ForeignKey("datasets.id"), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

# --- Reference Sets (E4.1) ---
class GenomeBuild(str, enum.Enum):
    GRCh38 = "GRCh38"
    GRCh37 = "GRCh37"

class ReferenceRole(str, enum.Enum):
    FASTA = "FASTA"
    FAI = "FAI"
    DICT = "DICT"
    BWA_INDEX = "BWA_INDEX"
    VEP_CACHE = "VEP_CACHE"  # опционально

class ReferenceSet(Base):
    __tablename__ = "reference_sets"
    id = Column(String, primary_key=True, default=uuid4)
    name = Column(String, nullable=False, index=True)
    genome_build = Column(Enum(GenomeBuild), nullable=False)
    components = Column(JSON, nullable=False)   # [{role, uri, md5?}]
    is_complete = Column(Integer, nullable=False, default=0)  # 1 = true, 0 = false
    created_at = Column(DateTime, default=datetime.utcnow)

# --- Workflows registry (E5.1) ---
class Workflow(Base):
    __tablename__ = "workflows"
    id = Column(String, primary_key=True, default=uuid4)
    name = Column(String, nullable=False, index=True)        # напр.: nf-core/dna-seq
    version = Column(String, nullable=False)                 # напр.: 3.10.0
    engine = Column(String, nullable=False, default="nextflow")
    repo = Column(String, nullable=True)                     # git URL
    revision = Column(String, nullable=True)                 # git tag/branch
    git_sha = Column(String, nullable=True)                  # зафиксированная ревизия
    lock = Column(JSON, nullable=False)                      # lockfile в JSON
    created_at = Column(DateTime, default=datetime.utcnow)

class RunStatus(str, enum.Enum):
    Queued = "Queued"
    Running = "Running"
    Succeeded = "Succeeded"
    Failed = "Failed"

class Run(Base):
    __tablename__ = "runs"
    id = Column(String, primary_key=True, default=uuid4)
    project_id = Column(String, ForeignKey("projects.id"), index=True, nullable=False)
    workflow_id = Column(String, ForeignKey("workflows.id"), nullable=False)
    reference_set_id = Column(String, ForeignKey("reference_sets.id"), nullable=False)
    sample_ids = Column(SAJSON, nullable=False, default=list)   # список IDs из таблицы samples
    params = Column(SAJSON, nullable=False, default=dict)       # произвольные параметры
    compute_profile = Column(String, nullable=False, default="local-docker")
    runner_job_id = Column(String, nullable=True)               # run_id из Runner
    status = Column(Enum(RunStatus), nullable=False, default=RunStatus.Queued)
    artifacts = Column(SAJSON, nullable=False, default=list)    # список S3 URI
    created_by = Column(String, ForeignKey("users.id"), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)