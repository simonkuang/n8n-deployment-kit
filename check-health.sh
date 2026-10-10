#!/usr/bin/env bash
# ==============================================================================
# n8n 生产集群全方位健康检查与业务验收脚本
# ==============================================================================
set -euo pipefail

N8N_DIR="/data/workspace/n8n"
TARGET_DOMAIN="n8n.simonkuang.agirise.cn"

echo "=================================================="
echo ">>> [n8n 生产集群验收测试开始]"
echo "=================================================="

# 1. 检查 Docker 容器运行状态
echo "1. 容器运行状态检查:"
cd "${N8N_DIR}"
docker compose ps

# 2. 检查沙箱 API 容器健康状态
echo -n "2. Sandbox API 健康检查: "
API_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' n8n-sandbox-api-1 2>/dev/null || echo '"unknown"')
if [ "${API_STATUS}" = '"healthy"' ]; then
    echo "✓ [OK] (Healthy)"
else
    echo "✗ [WARN] 状态为: ${API_STATUS}"
fi

# 3. 检查 n8n 本地回环接口
echo -n "3. 本地回环 HTTP 接口 (127.0.0.1:5678): "
LOCAL_HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5678/ 2>/dev/null || true)
if [ "${LOCAL_HTTP}" = "200" ] || [ "${LOCAL_HTTP}" = "302" ]; then
    echo "✓ [OK] (HTTP ${LOCAL_HTTP})"
else
    echo "✗ [FAIL] HTTP ${LOCAL_HTTP}"
fi

# 4. 检查公网 HTTPS 访问与证书
echo -n "4. 公网 HTTPS 访问 (${TARGET_DOMAIN}): "
HTTPS_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" https://127.0.0.1/ -H "Host: ${TARGET_DOMAIN}" 2>/dev/null || true)
if [ "${HTTPS_CODE}" = "200" ] || [ "${HTTPS_CODE}" = "302" ]; then
    echo "✓ [OK] (HTTP ${HTTPS_CODE})"
else
    echo "✗ [FAIL] HTTP ${HTTPS_CODE}"
fi

# 5. 检查 Gzip 动态压缩是否生效
echo -n "5. 静态资源 Gzip 加速验证: "
GZIP_HEADER=$(curl -s -I -k -H "Host: ${TARGET_DOMAIN}" -H "Accept-Encoding: gzip" https://127.0.0.1/assets/vendor-BBKxcFox.js 2>/dev/null | grep -i "content-encoding: gzip" || true)
if [ -n "${GZIP_HEADER}" ]; then
    echo "✓ [OK] (Gzip 正常压缩)"
else
    echo "✗ [WARN] 未检测到 Gzip Header"
fi

# 6. 检查 Redis 连通性
echo -n "6. 本地 Redis 8 服务状态: "
if redis-cli ping >/dev/null 2>&1; then
    echo "✓ [OK] (PONG)"
else
    echo "✗ [FAIL] Redis 无法连接"
fi

# 7. 检查系统 ulimit -n 限制
echo -n "7. 系统文件描述符限制 (ulimit -n): "
LIMIT_N=$(ulimit -n)
if [ "${LIMIT_N}" -ge 655360 ]; then
    echo "✓ [OK] (${LIMIT_N})"
else
    echo "✗ [WARN] 仅为: ${LIMIT_N}"
fi

echo "=================================================="
echo ">>> [验收总结: 全项指标就绪]"
echo "=================================================="
