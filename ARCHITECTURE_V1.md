# 幂等服务（idempotency-service）系统存档 v1.0

> **版本**：v1.0  
> **日期**：2026-02-28  
> **状态**：生产运行中

---

## 1. 系统概述

### 背景

n8n 工作流在处理订单、发送通知等业务时，存在因网络抖动、用户重复触发、定时任务重叠等原因导致**同一业务被重复执行**的风险。

### 解决方案

将幂等逻辑抽取为独立的 **FastAPI 微服务**，部署在 VPS 的 Docker 容器中。n8n 工作流通过两个 HTTP 请求节点接入，所有幂等判断由微服务负责。

### 核心原则

- n8n 只负责触发和业务逻辑，**不在 n8n 内保存任何幂等状态**
- 微服务持有数据库连接，用行锁保证并发安全
- 支持自动自愈（Recovery）：过期锁和失败重试由后台定时任务处理

---

## 2. 系统架构

```
┌─────────────────────────────────────────────────────┐
│  VPS (45.63.61.157) — Docker 环境（caddy-network）  │
│                                                     │
│  ┌──────────┐   HTTP 内网    ┌────────────────────┐ │
│  │   n8n    │ ────────────→  │ idempotency-service│ │
│  │(:5678)   │ ←──────────── │    (:8080)         │ │
│  └──────────┘                └────────┬───────────┘ │
│                                       │ psycopg2    │
│  ┌───────────────┐                   ↓             │
│  │     Caddy     │        ┌──────────────────────┐ │
│  │  (反向代理)   │        │ n8n-workflow-postgres │ │
│  └───────────────┘        │  DB: n8n_workflow_data│ │
│                            └──────────────────────┘ │
└─────────────────────────────────────────────────────┘

本地开发 → git push → GitHub Actions → 构建镜像 → SSH 部署 VPS
```

### 关键组件

| 组件 | 位置 | 说明 |
|------|------|------|
| 微服务代码 | GitHub：`olavininfo/idempotency-service` | FastAPI 应用 |
| Docker 镜像 | GHCR：`ghcr.io/olavininfo/idempotency-service:latest` | 生产镜像 |
| 服务运行位置 | VPS `/opt/idempotency-service/` | docker-compose + .env |
| 数据库 | VPS PostgreSQL 容器 `n8n-workflow-postgres` | 幂等记录存储 |

---

## 3. 数据库结构

### 数据库信息

| 项目 | 值 |
|------|-----|
| 容器名 | `n8n-workflow-postgres` |
| 数据库名 | `n8n_workflow_data` |
| 用户 | `n8nworkflow` |
| 所在 Docker 网络 | `caddy-network` |
| 连接端口 | `5432`（内网）/ `5433`（宿主机映射） |

### 核心表：`idempotency_keys`

```sql
CREATE TABLE idempotency_keys (
    id                 BIGSERIAL PRIMARY KEY,
    scope              VARCHAR(128)  NOT NULL,  -- 业务场景名（如 "order_process"）
    idempotency_key    VARCHAR(255)  NOT NULL,  -- 唯一业务 ID（如 "order-123"）
    status             VARCHAR(32)   NOT NULL,  -- PROCESSING / DONE / FAILED / CONFLICT
    payload_fingerprint VARCHAR(64)  DEFAULT '', -- 可选：请求内容 hash，用于防篡改
    attempt_count      INTEGER       DEFAULT 0,  -- 已尝试次数
    lock_expires_at    TIMESTAMPTZ,              -- 锁过期时间（PROCESSING 状态时有值）
    next_retry_at      TIMESTAMPTZ,              -- 下次重试时间（FAILED 状态时有值）
    last_error         TEXT,                     -- 最后一次错误信息（最多 4000 字符）
    last_error_at      TIMESTAMPTZ,              -- 最后一次错误时间
    created_at         TIMESTAMPTZ   DEFAULT now(),
    updated_at         TIMESTAMPTZ   DEFAULT now(),

    UNIQUE (scope, idempotency_key)              -- 联合唯一索引
);
```

### 状态流转图

```
                    ┌─────────┐
           首次请求  │         │
         ──────────→│PROCESSING│──────────────┐
                    │  (锁中)  │              │
                    └─────────┘              │
                         │                   │
              业务成功 complete(DONE)         │ 业务失败 complete(FAILED)
                         │                   │
                         ↓                   ↓
                    ┌──────┐          ┌──────────┐
                    │ DONE │          │  FAILED  │──→ 到期后 Recovery 重试
                    └──────┘          └──────────┘
                                            │
                                            │ payload 不一致
                                            ↓
                                      ┌──────────┐
                                      │ CONFLICT │
                                      └──────────┘
```

### 核心存储函数：`idempotency_acquire()`

```sql
-- 函数签名（PL/pgSQL，包含 FOR UPDATE 行锁保证并发安全）
CREATE FUNCTION idempotency_acquire(
    p_scope              VARCHAR,
    p_idempotency_key    VARCHAR,
    p_payload_fingerprint VARCHAR,
    p_ttl_seconds        INTEGER,
    p_max_attempts       INTEGER
) RETURNS TABLE (decision VARCHAR, attempt_count INTEGER, lock_expires_at TIMESTAMPTZ)
```

**返回的 decision 值说明：**

| decision | 含义 | n8n 应处理方式 |
|----------|------|--------------|
| `PROCEED` | 可执行，锁已获取 | 继续执行业务 |
| `SKIP_ALREADY_DONE` | 已成功处理过 | 跳过，返回成功 |
| `RETRY_LATER` | 正在处理中或重试时间未到 | 跳过本次，等待下次触发 |
| `CONFLICT` | 相同 key 但内容不一致 | 告警，人工检查 |

---

## 4. 微服务 API

### 基础 URL

```
http://idempotency-service:8080   ← n8n 内网调用（caddy-network）
```

### `POST /acquire` — 请求幂等锁

**请求体：**
```json
{
  "scope":               "order_process",   // 必填：业务场景名
  "idempotency_key":     "order-123",       // 必填：唯一业务 ID
  "payload_fingerprint": "",                // 可选：请求内容 hash
  "ttl_seconds":         900,               // 可选：锁超时秒数（默认 900）
  "max_attempts":        10                 // 可选：最大重试次数（默认 10）
}
```

**响应：**
```json
{
  "decision":        "PROCEED",            // 见上方 decision 表
  "attempt_count":   1,                    // 当前第几次尝试
  "lock_expires_at": "2026-02-28T09:00:00Z" // 锁过期时间（PROCEED 时有值）
}
```

---

### `POST /complete` — 标记执行结果

**请求体：**
```json
{
  "scope":             "order_process",
  "idempotency_key":   "order-123",
  "final_status":      "DONE",             // DONE / FAILED / CONFLICT
  "error_message":     "",                 // 失败时填写原因
  "attempt_count":     1,                  // 用于指数退避计算（FAILED 时）
  "base_retry_seconds": 60                 // FAILED 重试基础间隔秒数
}
```

**FAILED 重试间隔计算（指数退避）：**
```
delay = min(base_retry_seconds × 2^min(attempt_count, 6), 3600)
示例：60s → 120s → 240s → 480s → 960s → 1920s → 3600s（上限1小时）
```

**响应：**
```json
{ "ok": true, "status": "DONE" }
```

---

### `GET /health` — 健康检查

**响应：**
```json
{ "status": "ok", "db": "connected" }
```

---

## 5. 项目文件结构

```
idempotency-service/          ← 本地开发目录（Windows: d:\n8n skill\idempotency-service）
├── app/
│   ├── __init__.py
│   ├── main.py               ← FastAPI 入口，注册路由，生命周期管理
│   ├── database.py           ← psycopg2 连接池（ThreadedConnectionPool，max=10）
│   ├── recovery.py           ← APScheduler 后台定时任务（每 5 分钟自愈）
│   └── routers/
│       ├── __init__.py
│       ├── acquire.py        ← POST /acquire
│       ├── complete.py       ← POST /complete
│       └── health.py         ← GET /health
├── .env.example              ← 环境变量模板（已提交 git）
├── .gitignore
├── Dockerfile                ← 基于 python:3.11-slim，内置 curl
├── requirements.txt          ← fastapi, uvicorn, psycopg2-binary, apscheduler, requests
├── README.md
├── n8n_test_workflow.json    ← n8n 测试工作流导入文件
└── .github/
    └── workflows/
        └── deploy.yml        ← GitHub Actions CI/CD
```

### VPS 上的文件（`/opt/idempotency-service/`）

```
/opt/idempotency-service/
├── docker-compose.yml        ← 服务定义（接入 caddy-network）
└── .env                      ← 真实数据库密码（不进 git）
```

---

## 6. CI/CD 流程

### 触发条件

`git push origin main` 自动触发

### 执行流程

```
GitHub Actions Runner（ubuntu-latest）
  1. Checkout 代码
  2. 登录 GHCR（用 Secret: GHCR_TOKEN）
  3. docker build（约 30 秒）
  4. docker push → ghcr.io/olavininfo/idempotency-service:latest
  5. SSH 进 VPS（用 Secret: VPS_SSH_KEY）
  6. docker pull + docker compose up -d --force-recreate（约 10 秒）
  7. 健康检查验证
全程约 1.5 分钟
```

### GitHub Secrets 配置

| Secret 名 | 内容 |
|-----------|------|
| `GHCR_TOKEN` | GitHub PAT（含 workflow + write:packages 权限） |
| `VPS_HOST` | `45.63.61.157` |
| `VPS_USER` | `root` |
| `VPS_SSH_KEY` | ed25519 私钥内容（finley_common_key） |
| `DB_PASSWORD` | 数据库密码 |

---

## 7. n8n 接入模板

### 任何业务工作流接入只需 3 个节点

```
[HTTP Request] POST http://idempotency-service:8080/acquire
Body (JSON):
{
  "scope":            "your_workflow_name",
  "idempotency_key":  "{{ $json.unique_id }}",
  "ttl_seconds":      900,
  "max_attempts":     3
}

        ↓

[IF] {{ $json.decision }} == "PROCEED"
  ├── 是 → [业务节点...] → [HTTP Request] POST /complete { "final_status": "DONE" }
  └── 否 → [结束/日志] 显示 decision 原因
```

### 失败时的 complete 调用

在 n8n 工作流的 Error Workflow 或失败分支中调用：

```json
{
  "scope":          "your_workflow_name",
  "idempotency_key": "{{ $json.idempotency_key }}",
  "final_status":   "FAILED",
  "error_message":  "{{ $json.error.message }}",
  "attempt_count":  "{{ $json.attempt_count }}"
}
```

---

## 8. Recovery 自愈机制

- **触发频率**：每 5 分钟（由 `RECOVERY_INTERVAL_MINUTES` 控制）
- **扫描范围**：
  - `PROCESSING` 且 `lock_expires_at <= now()`（锁过期，可能是异常中断）
  - `FAILED` 且 `next_retry_at <= now()`（到达重试时间）
- **回调方式**：向 `RECOVERY_CALLBACK_URL`（.env 配置）发送 POST 请求，触发对应业务工作流的 Webhook 重新执行
- **当前状态**：`RECOVERY_CALLBACK_URL` 未配置（暂不自动重试，仅记录）

---

## 9. 运维操作手册

### 查看服务状态

```bash
docker ps | grep idempotency
docker logs idempotency-service --tail 50
```

### 健康检查

```bash
docker exec idempotency-service python -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health').read().decode())"
```

### 手动更新服务（代码未变，只是强制重启）

```bash
cd /opt/idempotency-service
docker compose pull
docker compose up -d --force-recreate
```

### 查看幂等记录

```bash
# 登录数据库容器
docker exec -it n8n-workflow-postgres psql -U n8nworkflow -d n8n_workflow_data

# 查询所有记录
SELECT scope, idempotency_key, status, attempt_count, created_at
FROM idempotency_keys
ORDER BY created_at DESC
LIMIT 20;

# 重置测试记录
DELETE FROM idempotency_keys WHERE idempotency_key = 'order-001';
```

---

## 10. 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v1.0 | 2026-02-28 | 初始版本：FastAPI + Docker + GitHub Actions CI/CD，接入 n8n |
