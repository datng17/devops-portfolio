# devops-portfolio/app/main.py
import logging

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import text

from app.db import SessionLocal, db_healthy

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("app")

app = FastAPI(title="DevOps Portfolio API", version="1.0.0")


class ItemIn(BaseModel):
    name: str = Field(min_length=1, max_length=255)


@app.get("/health")
def health():
    """Liveness probe: process is up and serving."""
    return {"status": "ok"}


@app.get("/health/db")
def health_db():
    """Readiness probe: database is reachable (DB ping)."""
    if db_healthy():
        return {"status": "ok", "db": "up"}
    raise HTTPException(status_code=503, detail="database unavailable")


@app.get("/items")
def list_items():
    with SessionLocal() as session:
        rows = session.execute(text("SELECT id, name FROM items")).mappings().all()
        return {"items": [dict(r) for r in rows]}


@app.post("/items", status_code=201)
def create_item(item: ItemIn):
    with SessionLocal() as session:
        result = session.execute(
            text("INSERT INTO items (name) VALUES (:n)"), {"n": item.name}
        )
        session.commit()
        new_id = result.lastrowid
    log.info("item created id=%s name=%s", new_id, item.name)
    return {"id": new_id, "name": item.name}
