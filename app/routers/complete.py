from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional
from app.database import get_db

router = APIRouter(tags=["complete"])


class CompleteRequest(BaseModel):
    scope: str
    idempotency_key: str
    final_status: str          # DONE | FAILED | CONFLICT
    error_message: Optional[str] = ""
    attempt_count: int = 1
    base_retry_seconds: int = 60


@router.post("/complete")
def complete(req: CompleteRequest):
    status = req.final_status.upper()
    if status not in ("DONE", "FAILED", "CONFLICT"):
        raise HTTPException(status_code=400, detail=f"Invalid final_status: {status}")

    with get_db() as conn:
        try:
            with conn.cursor() as cur:
                if status == "DONE":
                    cur.execute(
                        """UPDATE idempotency_keys
                           SET status='DONE', lock_expires_at=NULL, next_retry_at=NULL,
                               last_error=NULL, last_error_at=NULL, updated_at=now()
                           WHERE scope=%s AND idempotency_key=%s
                           RETURNING status, updated_at""",
                        (req.scope, req.idempotency_key),
                    )

                elif status == "FAILED":
                    # 指数退避：min(base * 2^min(attempt,6), 3600)
                    delay = min(
                        req.base_retry_seconds * (2 ** min(req.attempt_count, 6)), 3600
                    )
                    cur.execute(
                        """UPDATE idempotency_keys
                           SET status='FAILED', lock_expires_at=NULL,
                               last_error=LEFT(%s,4000), last_error_at=now(),
                               next_retry_at=now() + (%s || ' seconds')::interval,
                               updated_at=now()
                           WHERE scope=%s AND idempotency_key=%s
                           RETURNING status, next_retry_at, updated_at""",
                        (
                            req.error_message,
                            str(int(delay)),
                            req.scope,
                            req.idempotency_key,
                        ),
                    )

                else:  # CONFLICT
                    cur.execute(
                        """UPDATE idempotency_keys
                           SET status='CONFLICT', lock_expires_at=NULL,
                               last_error=LEFT(%s,4000), last_error_at=now(),
                               updated_at=now()
                           WHERE scope=%s AND idempotency_key=%s
                           RETURNING status, updated_at""",
                        (req.error_message, req.scope, req.idempotency_key),
                    )

                row = cur.fetchone()

            return {"ok": True, "status": row[0]}
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
