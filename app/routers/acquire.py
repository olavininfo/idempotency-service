from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from app.database import get_db

router = APIRouter(tags=["acquire"])


class AcquireRequest(BaseModel):
    scope: str
    idempotency_key: str
    payload_fingerprint: str = ""
    ttl_seconds: int = 900
    max_attempts: int = 10


@router.post("/acquire")
def acquire(req: AcquireRequest):
    with get_db() as conn:
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT decision, attempt_count, lock_expires_at
                       FROM idempotency_acquire(%s, %s, %s, %s, %s)""",
                    (
                        req.scope,
                        req.idempotency_key,
                        req.payload_fingerprint,
                        req.ttl_seconds,
                        req.max_attempts,
                    ),
                )
                row = cur.fetchone()

            return {
                "decision": row[0],
                "attempt_count": row[1],
                "lock_expires_at": row[2].isoformat() if row[2] else None,
            }
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
