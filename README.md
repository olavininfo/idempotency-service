# idempotency-service

通用幂等门卫微服务，供 n8n 工作流调用。

## API

| 接口 | 说明 |
|------|------|
| `POST /acquire` | 请求幂等锁，返回 decision |
| `POST /complete` | 标记执行结果 |
| `GET /health` | 服务与 DB 状态检查 |

## 本地运行

```bash
cp .env.example .env
# 编辑 .env 填写数据库密码
pip install -r requirements.txt
uvicorn app.main:app --port 8080
```

## Decision 说明

| decision | 含义 |
|----------|------|
| `PROCEED` | 可以执行，锁已获取 |
| `SKIP_ALREADY_DONE` | 已成功处理过，跳过 |
| `RETRY_LATER` | 正在处理中或重试时间未到 |
| `CONFLICT` | 相同 key 但 payload 不一致 |
