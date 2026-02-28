from fastapi import APIRouter
from app.database import get_db

router = APIRouter(tags=["health"])


@router.get("/health")
def health_check():
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return {"status": "ok", "db": "connected"}
    except Exception as e:
        return {"status": "error", "db": str(e)}
