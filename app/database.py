"""数据库连接池管理（psycopg2 ThreadedConnectionPool）"""
import os
import logging
import psycopg2
from psycopg2 import pool
from contextlib import contextmanager

logger = logging.getLogger(__name__)

_pool: pool.ThreadedConnectionPool | None = None


async def init_pool() -> None:
    global _pool
    db_schema = os.getenv("DB_SCHEMA", "idempotency")
    _pool = psycopg2.pool.ThreadedConnectionPool(
        minconn=1,
        maxconn=10,
        host=os.getenv("DB_HOST", "n8n-workflow-postgres"),
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "n8n_workflow_data"),
        user=os.getenv("DB_USER", "n8nworkflow"),
        password=os.getenv("DB_PASSWORD", ""),
        options=f"-c search_path={db_schema}",   # 自动指向指定 schema
    )
    logger.info(f"Database connection pool initialized (schema: {db_schema})")


async def close_pool() -> None:
    if _pool:
        _pool.closeall()
        logger.info("Database connection pool closed")


@contextmanager
def get_db():
    """上下文管理器：自动归还连接，自动 rollback on error"""
    conn = _pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        _pool.putconn(conn)
