#!/usr/bin/env bash
# ==============================================================================
# n8n 生产级全栈集群自动化部署与灾难恢复脚本
# 用途: 支持在任何安装好 Docker 的主机上全新一键拉起完整的 n8n + Sandbox 隔离环境
# ==============================================================================
set -euo pipefail

N8N_DIR="/data/workspace/n8n"
COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
ENV_FILE="${N8N_DIR}/.env"
UPGRADE_FILE="${N8N_DIR}/upgrade.sh"

echo "=================================================="
echo ">>> 开始部署/维护 n8n 全套生产级沙箱集群..."
echo "=================================================="

mkdir -p "${N8N_DIR}/data"

# 1. 密钥生成与对齐
CONFIG_FILE="${N8N_DIR}/data/config"
ENCRYPTION_KEY="LoBNZblwNyZeB/PYP12lCJkWvhcd+PJM"
if [ -f "${CONFIG_FILE}" ]; then
    DETECTED=$(grep -o '"encryptionKey":"[^"]*"' "${CONFIG_FILE}" | cut -d'"' -f4 || true)
    if [ -n "${DETECTED}" ]; then
        ENCRYPTION_KEY="${DETECTED}"
    fi
fi

RUNNERS_AUTH_TOKEN=$(openssl rand -hex 24)
SANDBOX_API_KEY=$(openssl rand -hex 24)
REGISTRATION_TOKEN=$(openssl rand -hex 24)
RUNNER_KEY=$(openssl rand -hex 24)

# 2. 写入环境配置文件
cat << EOF > "${ENV_FILE}"
N8N_VERSION=latest
N8N_SANDBOX_VERSION=1.3.1
N8N_HOST=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
NODE_ENV=production
GENERIC_TIMEZONE=Asia/Shanghai
TZ=Asia/Shanghai
WEBHOOK_URL=https://n8n.simonkuang.agirise.cn/

# 固化加密密钥
N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# 自动修剪执行历史
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000

# Task Runners 配置
N8N_RUNNERS_MODE=external
N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
N8N_RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}

# Sandbox 隔离沙箱认证配置
N8N_INSTANCE_AI_SANDBOX_ENABLED=true
N8N_INSTANCE_AI_SANDBOX_PROVIDER=n8n-sandbox
N8N_INSTANCE_AI_SANDBOX_API_URL=http://sandbox-api:8080
N8N_SANDBOX_SERVICE_URL=http://sandbox-api:8080
SANDBOX_API_KEYS=${SANDBOX_API_KEY}
N8N_SANDBOX_SERVICE_API_KEY=${SANDBOX_API_KEY}
SANDBOX_API_RUNNER_REGISTRATION_TOKEN=${REGISTRATION_TOKEN}
SANDBOX_RUNNER_REGISTRATION_TOKEN=${REGISTRATION_TOKEN}
SANDBOX_API_RUNNER_API_KEY=${RUNNER_KEY}
SANDBOX_RUNNER_API_KEYS=${RUNNER_KEY}
EOF
chmod 600 "${ENV_FILE}"

# 3. 写入完整 Docker Compose 编排
cat << 'EOF' > "${COMPOSE_FILE}"
volumes:
  sandbox-tls:

services:
  sandbox-certs:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:${N8N_SANDBOX_VERSION}
    user: '0:0'
    entrypoint: ['sh', '-c']
    command:
      - >
        bootstrap-mtls.sh --out-dir /tls --api-san sandbox-api
        --control-san-prefix sandbox-runner --world-readable &&
        chown -R sandbox-api:sandbox-api /tls/api && chmod -R a+rX /tls
    environment:
      NUM_RUNNERS: '1'
    volumes:
      - sandbox-tls:/tls

  sandbox-api:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:${N8N_SANDBOX_VERSION}
    restart: unless-stopped
    depends_on:
      sandbox-certs:
        condition: service_completed_successfully
    env_file: .env
    environment:
      SANDBOX_API_GRPC_TLS_CERT_FILE: /tls/api/grpc-server.crt
      SANDBOX_API_GRPC_TLS_KEY_FILE: /tls/api/grpc-server.key
      SANDBOX_API_GRPC_TLS_CLIENT_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/api/control-grpc-api-client.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/api/control-grpc-api-client.key
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_SERVER_NAME: sandbox-runner-1
    volumes:
      - sandbox-tls:/tls:ro
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://localhost:8080/healthz']
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s

  sandbox-runner-1:
    image: ghcr.io/n8n-io/n8n-sandbox-service-runner-dind:${N8N_SANDBOX_VERSION}
    privileged: true
    restart: unless-stopped
    depends_on:
      sandbox-api:
        condition: service_healthy
    env_file: .env
    environment:
      SANDBOX_RUNNER_API_GRPC_ADDR: sandbox-api:9090
      SANDBOX_RUNNER_HTTP_BASE_URL: https://sandbox-runner-1:8080
      SANDBOX_RUNNER_CONTROL_GRPC_LISTEN_ADDR: ':9091'
      SANDBOX_RUNNER_CONTROL_GRPC_ADVERTISE_ADDR: sandbox-runner-1:9091
      SANDBOX_RUNNER_ID: runner-1
      SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE: ghcr.io/n8n-io/n8n-sandbox-service-sandbox:${N8N_SANDBOX_VERSION}
      SANDBOX_RUNNER_REGISTRATION_GRPC_CA_FILE: /tls/runner/ca.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_CERT_FILE: /tls/runner/grpc-client.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_KEY_FILE: /tls/runner/grpc-client.key
      SANDBOX_RUNNER_REGISTRATION_GRPC_SERVER_NAME: sandbox-api
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/runner/control-grpc-server.crt
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/runner/control-grpc-server.key
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CLIENT_CA_FILE: /tls/runner/ca.crt
    volumes:
      - sandbox-tls:/tls:ro

  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    container_name: n8n
    restart: unless-stopped
    depends_on:
      sandbox-api:
        condition: service_healthy
    ports:
      - "127.0.0.1:5678:5678"
    env_file: .env
    volumes:
      - /data/workspace/n8n/data:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"

  runners:
    image: ghcr.io/n8n-io/runners:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      - n8n
    environment:
      N8N_RUNNERS_AUTH_TOKEN: ${N8N_RUNNERS_AUTH_TOKEN}
      N8N_RUNNERS_TASK_BROKER_URI: http://n8n:5679
      N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT: '15'
EOF

# 4. 写入一键升级脚本
cat << 'EOF' > "${UPGRADE_FILE}"
#!/usr/bin/env bash
set -euo pipefail
cd /data/workspace/n8n
echo "===>>> 正在拉取全栈最新官方镜像..."
docker compose pull
echo "===>>> 正在平滑重启服务栈..."
docker compose up -d
echo "===>>> 升级成功！当前 n8n 运行版本:"
docker exec n8n n8n --version
EOF
chmod +x "${UPGRADE_FILE}"

# 5. 权限与拉起
chown -R 1000:1000 "${N8N_DIR}/data"
cd "${N8N_DIR}"
docker compose pull
docker compose up -d

echo "=================================================="
echo ">>> n8n 全栈沙箱集群部署完毕！"
echo "=================================================="
