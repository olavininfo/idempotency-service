"""后台定时自愈任务：每5分钟扫描过期锁和可重试记录，触发回调"""
import os
import logging
import requests
from apscheduler.schedulers.background import BackgroundScheduler
from app.database import get_db

logger = logging.getLogger(__name__)


def run_recovery() -> None:
    """扫描可恢复的幂等记录，通过 Webhook 回调触发业务重执行"""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """SELECT scope, idempotency_key, payload_fingerprint,
                              status, attempt_count
                       FROM idempotency_keys
                       WHERE
                         (status = 'PROCESSING'
                          AND lock_expires_at IS NOT NULL
                          AND lock_expires_at <= now())
                         OR
                         (status = 'FAILED'
                          AND next_retry_at IS NOT NULL
                          AND next_retry_at <= now())
                       ORDER BY updated_at ASC
                       LIMIT 50"""
                )
                rows = cur.fetchall()

        if not rows:
            logger.debug("Recovery: no recoverable items")
            return

        logger.info(f"Recovery: found {len(rows)} recoverable items")

        callback_url = os.getenv("RECOVERY_CALLBACK_URL", "").strip()
        if not callback_url:
            logger.warning(
                "Recovery: RECOVERY_CALLBACK_URL not set, items found but not triggered"
            )
            return

        for row in rows:
            try:
                resp = requests.post(
                    callback_url,
                    json={
                        "scope": row[0],
                        "idempotency_key": row[1],
                        "payload_fingerprint": row[2] or "",
                        "status": row[3],
                        "attempt_count": row[4],
                        "replay": True,
                    },
                    timeout=10,
                )
                logger.info(
                    f"Recovery triggered: {row[0]}/{row[1]} → HTTP {resp.status_code}"
                )
            except Exception as e:
                logger.error(f"Recovery callback failed for {row[0]}/{row[1]}: {e}")

    except Exception as e:
        logger.error(f"Recovery scan error: {e}")


def start_recovery_scheduler() -> None:
    interval_minutes = int(os.getenv("RECOVERY_INTERVAL_MINUTES", "5"))
    scheduler = BackgroundScheduler()
    scheduler.add_job(run_recovery, "interval", minutes=interval_minutes, id="recovery")
    scheduler.start()
    logger.info(f"Recovery scheduler started (every {interval_minutes} minutes)")
