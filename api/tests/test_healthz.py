from fastapi.testclient import TestClient
import sys, pathlib

# Добавляем директорию api/ в sys.path, чтобы импортировать main.py как модуль
sys.path.append(str(pathlib.Path(__file__).resolve().parents[1]))
from main import app  # type: ignore

client = TestClient(app)

def test_healthz_ok():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}
