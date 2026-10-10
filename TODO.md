# n8n 生产集群演进与运维待办事项 (TODO)

本文档记录本次 n8n 生产集群上线交付后，推荐跟进的架构演进、自动化运维、高可用容灾与安全加固任务。

---

## 一、 架构与存储演进 (Architecture & Storage)

- [ ] **从 SQLite 平滑迁移至 PostgreSQL 独立数据库**
  - **背景**：当前使用 SQLite 存储工作流与执行记录，在单机中低并发场景下性能优良；但当长线并发调度增加、执行历史数据膨胀时，SQLite 可能面临写锁瓶颈。
  - **行动项**：
    1. 评估在 Docker Compose 中引入 `postgres:16-alpine` 服务或复用宿主机高可用 PostgreSQL。
    2. 使用 n8n 官方 CLI 导出已有工作流与凭据：`n8n export:workflow --all` 与 `n8n export:credentials --all --decrypted`。
    3. 配置 `.env` 中的 `DB_TYPE=postgresdb` 并恢复数据，验证完整性。

- [ ] **启用 Redis 队列模式 (Queue Mode) 实现水平扩展**
  - **背景**：宿主机已部署并调优官方 Redis 8 (监听 `127.0.0.1` 及 Docker 桥接网卡 `172.17.0.1`)。
  - **行动项**：
    1. 当工作流执行吞吐量进一步提升时，在 `.env` 中开启 `EXECUTIONS_MODE=queue`。
    2. 配置 `QUEUE_BULL_REDIS_HOST=172.17.0.1` 与 `QUEUE_BULL_REDIS_PORT=6379`。
    3. 编排多实例 `n8n-worker` 实现并发任务的负载均衡分发。

---

## 二、 自动化容灾与备份 (Backup & Disaster Recovery)

- [ ] **配置自动化定时异地备份机制**
  - **背景**：防止硬件单点故障或磁盘损坏造成生产数据丢失。
  - **行动项**：
    1. 编写备份脚本 `/data/workspace/n8n/backup.sh`，定时（如每日凌晨 3:00）对 `/data/workspace/n8n/data/` 目录进行 tar 打包与 sqlite 备份。
    2. 将压缩备份通过 rsync / rclone 或对象存储（如 Cloudflare R2 / S3）自动同步至远端存储。
    3. 设置本地保留周期（保留最近 7 天的每日备份快照），并在 Crontab 中配置自动清理。

- [ ] **异地灾备恢复演练 (Disaster Recovery Drill)**
  - **行动项**：
    1. 验证在全新机器上使用 `n8n-deployment-kit/deploy-stack.sh` + 历史备份 tar 包的快速拉起能力。
    2. 校验在恢复旧数据时 `N8N_ENCRYPTION_KEY` 的解密正确性。

---

## 三、 安全与证书运维 (Security & Certificate Management)

- [ ] **泛域名 SSL 证书自动热重载与监控**
  - **背景**：当前证书由用户独立维护，路径为 `/usr/local/openresty/nginx/conf/ssl/_.simonkuang.agirise.cn.*`。
  - **行动项**：
    1. 在用户证书自动更新钩子 (hook) 中添加 `systemctl reload openresty` 指令，实现新证书免重启无缝生效。
    2. 部署证书有效期探测告警（例如当剩余天数 < 15 天时发送告警提醒）。

- [ ] **访问审计与 Webhook IP 速率限制 (Rate Limiting)**
  - **行动项**：
    1. 在 OpenResty 中针对对外 Webhook 入口路径 `/webhook/*` 增加 `limit_req_zone` 速率限制，防止恶意洪峰攻击或滥用。
    2. 限制管理后台 `/signin` 访问尝试频率。

---

## 四、 监控、告警与可观测性 (Observability)

- [ ] **容器与系统资源健康探针集成**
  - **行动项**：
    1. 将本地 `check-health.sh` 脚本配置为服务器系统 Cron 巡检任务（例如每 10 分钟运行一次）。
    2. 当检测到非 200 响应、容器异常退出或沙箱 Unhealthy 时，对接 Telegram Bot、企业微信或 Webhook 发出告警。
    3. 监控宿主机磁盘容量（特别是 `/data/workspace/n8n/data`）与内存占用。

---

## 五、 AI 与进阶能力集成 (AI Capabilities)

- [ ] **大语言模型与外部系统凭据集成**
  - **行动项**：
    1. 登录 n8n 界面完成首次管理员账号注册（`https://n8n.simonkuang.agirise.cn/`）。
    2. 在 Credentials 中接入 OpenAI / Anthropic / Gemini API Key 等 AI 服务。
    3. 测试高级 AI Agent 与 Sandboxed Code 节点的协同运行效果。
