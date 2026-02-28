"""FastAPI 应用入口"""
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from app.database import init_pool, close_pool
from app.recovery import start_recovery_scheduler
from app.routers import acquire, complete, health

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    start_recovery_scheduler()
    yield
    await close_pool()


app = FastAPI(
    title="Idempotency Service",
    description="通用幂等门卫服务，供 n8n 工作流调用",
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(health.router)
app.include_router(acquire.router)
app.include_router(complete.router)
