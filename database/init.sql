-- =============================================================
-- 幂等服务数据库初始化 SQL
-- 数据库：任意已有 PostgreSQL 数据库
-- Schema：idempotency（独立 schema，与业务表隔离）
-- 版本：v1.0  日期：2026-02-28
-- 说明：在目标数据库中直接执行此脚本完成全部初始化
-- =============================================================

-- 0. 创建独立 Schema（如已存在则跳过）
-- =============================================================
CREATE SCHEMA IF NOT EXISTS idempotency;

-- 将 schema 权限授予微服务用户（按实际用户名替换）
-- GRANT ALL ON SCHEMA idempotency TO n8nworkflow;
-- GRANT ALL ON ALL TABLES IN SCHEMA idempotency TO n8nworkflow;
-- GRANT ALL ON ALL SEQUENCES IN SCHEMA idempotency TO n8nworkflow;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA idempotency TO n8nworkflow;

-- 1. 创建幂等记录主表
-- =============================================================
CREATE TABLE IF NOT EXISTS idempotency.idempotency_keys (
    id                  BIGSERIAL       PRIMARY KEY,
    scope               VARCHAR(128)    NOT NULL,
    idempotency_key     VARCHAR(255)    NOT NULL,
    status              VARCHAR(32)     NOT NULL            DEFAULT 'PROCESSING',
    payload_fingerprint VARCHAR(64)     NOT NULL DEFAULT '',
    attempt_count       INTEGER         NOT NULL DEFAULT 0,
    lock_expires_at     TIMESTAMPTZ,
    next_retry_at       TIMESTAMPTZ,
    last_error          TEXT,
    last_error_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CONSTRAINT uq_idempotency_scope_key UNIQUE (scope, idempotency_key)
);

-- 2. 索引
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_idempotency_scope_key
    ON idempotency.idempotency_keys (scope, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_idempotency_recovery
    ON idempotency.idempotency_keys (status, lock_expires_at, next_retry_at)
    WHERE status IN ('PROCESSING', 'FAILED');

-- 3. 核心函数：idempotency_acquire()
-- =============================================================
-- 功能：原子性地申请幂等锁，包含完整的并发安全逻辑（FOR UPDATE 行锁）
-- 返回：decision（决策）、attempt_count（第几次尝试）、lock_expires_at（锁过期时间）
CREATE OR REPLACE FUNCTION idempotency_acquire(
    p_scope               VARCHAR,   -- 业务场景名
    p_idempotency_key     VARCHAR,   -- 唯一业务 ID
    p_payload_fingerprint VARCHAR,   -- 请求内容 hash（传空字符串则跳过校验）
    p_ttl_seconds         INTEGER,   -- 锁超时秒数（建议 900）
    p_max_attempts        INTEGER    -- 最大允许尝试次数
)
RETURNS TABLE (
    decision        VARCHAR,
    attempt_count   INTEGER,
    lock_expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_record        idempotency_keys%ROWTYPE;
    v_lock_expires  TIMESTAMPTZ;
    v_decision      VARCHAR;
    v_attempt_count INTEGER;
BEGIN
    -- 加行锁（SKIP LOCKED：并发时跳过已锁定行，立即返回 RETRY_LATER，不阻塞）
    SELECT * INTO v_record
    FROM idempotency_keys
    WHERE idempotency_keys.scope           = p_scope
      AND idempotency_keys.idempotency_key = p_idempotency_key
    FOR UPDATE SKIP LOCKED;

    -- 场景一：记录不存在 → 首次执行，直接插入并返回 PROCEED
    IF NOT FOUND THEN
        v_lock_expires  := now() + (p_ttl_seconds || ' seconds')::INTERVAL;
        v_attempt_count := 1;

        INSERT INTO idempotency_keys (
            scope, idempotency_key, status,
            payload_fingerprint, attempt_count,
            lock_expires_at, created_at, updated_at
        ) VALUES (
            p_scope, p_idempotency_key, 'PROCESSING',
            p_payload_fingerprint, v_attempt_count,
            v_lock_expires, now(), now()
        );

        RETURN QUERY SELECT 'PROCEED'::VARCHAR, v_attempt_count, v_lock_expires;
        RETURN;
    END IF;

    -- 场景二：锁被其他进程持有（SKIP LOCKED 未拿到锁）→ 立即返回 RETRY_LATER
    IF v_record.id IS NULL THEN
        RETURN QUERY SELECT 'RETRY_LATER'::VARCHAR, 0, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- 场景三：已成功完成 → 跳过
    IF v_record.status = 'DONE' THEN
        RETURN QUERY SELECT 'SKIP_ALREADY_DONE'::VARCHAR, v_record.attempt_count, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- 场景四：payload fingerprint 不一致 → 冲突告警
    IF p_payload_fingerprint != ''
       AND v_record.payload_fingerprint != ''
       AND v_record.payload_fingerprint != p_payload_fingerprint THEN
        RETURN QUERY SELECT 'CONFLICT'::VARCHAR, v_record.attempt_count, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- 场景五：超过最大重试次数 → 停止重试
    IF v_record.attempt_count >= p_max_attempts THEN
        RETURN QUERY SELECT 'RETRY_LATER'::VARCHAR, v_record.attempt_count, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- 场景六：PROCESSING 且锁未过期 → 正在处理中，返回 RETRY_LATER
    IF v_record.status = 'PROCESSING'
       AND v_record.lock_expires_at IS NOT NULL
       AND v_record.lock_expires_at > now() THEN
        RETURN QUERY SELECT 'RETRY_LATER'::VARCHAR, v_record.attempt_count, v_record.lock_expires_at;
        RETURN;
    END IF;

    -- 场景七：FAILED 且重试时间未到 → 返回 RETRY_LATER
    IF v_record.status = 'FAILED'
       AND v_record.next_retry_at IS NOT NULL
       AND v_record.next_retry_at > now() THEN
        RETURN QUERY SELECT 'RETRY_LATER'::VARCHAR, v_record.attempt_count, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    -- 场景八：锁过期（PROCESSING 异常中断）或 FAILED 已到重试时间 → 重新执行
    v_attempt_count := v_record.attempt_count + 1;
    v_lock_expires  := now() + (p_ttl_seconds || ' seconds')::INTERVAL;

    UPDATE idempotency_keys
    SET status              = 'PROCESSING',
        attempt_count       = v_attempt_count,
        lock_expires_at     = v_lock_expires,
        next_retry_at       = NULL,
        payload_fingerprint = CASE
                                WHEN p_payload_fingerprint != '' THEN p_payload_fingerprint
                                ELSE payload_fingerprint
                              END,
        updated_at          = now()
    WHERE idempotency_keys.scope           = p_scope
      AND idempotency_keys.idempotency_key = p_idempotency_key;

    RETURN QUERY SELECT 'PROCEED'::VARCHAR, v_attempt_count, v_lock_expires;
END;
$$;

-- 4. 可选：清理工具函数（手动清理过期的 DONE 记录，释放空间）
-- =============================================================
CREATE OR REPLACE FUNCTION idempotency_cleanup(p_days_old INTEGER DEFAULT 30)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM idempotency_keys
    WHERE status = 'DONE'
      AND updated_at < now() - (p_days_old || ' days')::INTERVAL;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

-- 使用示例（清理 30 天前的 DONE 记录）：
-- SELECT idempotency_cleanup(30);

-- =============================================================
-- 验证安装（运行后应无错误）
-- =============================================================
-- SELECT COUNT(*) FROM idempotency_keys;
-- SELECT idempotency_acquire('test', 'key-001', '', 900, 3);
-- SELECT * FROM idempotency_keys WHERE idempotency_key = 'key-001';
-- DELETE FROM idempotency_keys WHERE idempotency_key = 'key-001';
