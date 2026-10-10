# n8n 生产级隔离沙箱集群部署与运维完全手册

## 1. 架构总览与拓扑

本项目部署在 `racknerd` 服务器，采用 **Docker Compose 官方标准架构**，深度集成了 **全套代码执行隔离沙箱（Code Execution Sandbox）**、**本地持久化缓存（Redis 8）** 以及 **OpenResty 边缘反向代理加速**。

### 1.1 拓扑架构图
```mermaid
flowchart TD
    Client["客户端浏览器"] -->|HTTPS 443 / HTTP 80 (Gzip)| OpenResty["OpenResty 反向代理网关\n(n8n.simonkuang.agirise.cn)"]
    OpenResty -->|反向代理 + WebSocket| N8N["n8n 核心主容器 (n8n)\n127.0.0.1:5678"]

    subgraph SandboxCluster ["代码执行沙箱隔离集群 (Sandbox Stack)"]
        Certs["sandbox-certs\n内部 mTLS 双向证书生成"] -->|证书准备就绪| Api["sandbox-api\n沙箱调度控制中心 (Healthcheck)"]
        Api -->|健康就绪| Runner["sandbox-runner-1\nDocker-in-Docker 隔离沙箱"]
        Api -->|健康就绪| N8N
        N8N --> Runners["runners\n多语言外部任务运行器"]
    end

    subgraph Storage ["数据持久化与底层服务"]
        N8N -->|挂载持久化| LocalData["宿主机数据卷\n/data/workspace/n8n/data"]
        N8N -.->|内网连接 172.17.0.1:6379| Redis["Redis 8 服务 (宿主机 Systemd 托管)\n低频落盘 / 禁用 AOF"]
    end
```

---

## 2. 生产环境避坑指南 (Lessons Learned)

| 核心风险点 | 事故表现 | 规避与防护设计 |
| :--- | :--- | :--- |
| **执行历史无限膨胀** | 默认保存所有工作流数据，数月内几十 GB 打满磁盘导致数据库崩溃 | 强制开启自动修剪：`EXECUTIONS_DATA_PRUNE=true`，保留周期限制为 7 天（168 小时），最大执行条数 50,000 条 |
| **加密密钥丢失** | 容器重建或数据重挂载后随机密钥变动，导致数据库内全部 API Key/Token 无法解密报废 | 固化提取历史唯一密钥，在 `.env` 中严格绑定 `N8N_ENCRYPTION_KEY` |
| **代码执行逃逸/提权** | Code 节点在主容器内执行，恶意代码或第三方库偷取环境变量敏感凭据 | 引入全套配套沙箱（`sandbox-api` + `sandbox-runner-1`），不受信代码在 Dind 容器内隔离运行 |
| **Webhook 域名回环** | 在反向代理架构下第三方服务回调地址默认为 localhost 导致回调失败 | 显式注入对外地址：`WEBHOOK_URL=https://n8n.simonkuang.agirise.cn/` |
| **前端 SPA 跨国白屏** | 前端静态打包文件体积达 11MB+，海外 VPS 直连下载耗时长导致数十秒纯白屏 | OpenResty 虚拟主机开启 Gzip 动态压缩（级别 6），传输体积由 11MB 降至 2MB，加载速度提升 80% |
| **高并发文件句柄耗尽** | 默认 ulimit 仅为 1024，高并发或打开多个长连接时触发 `Too many open files` | 全面提升内核、PAM 与 Systemd 上限至 `6553600` |

---

## 3. 服务器资产与目录结构规范

### 3.1 核心资产
* **访问域名**：`https://n8n.simonkuang.agirise.cn/`
* **公网证书路径**：
  * 公钥链：`/usr/local/openresty/nginx/conf/ssl/_.simonkuang.agirise.cn.fullchain.cer`
  * 私钥：`/usr/local/openresty/nginx/conf/ssl/_.simonkuang.agirise.cn.key`
* **OpenResty 配置文件**：`/usr/local/openresty/nginx/conf/vhosts/n8n.simonkuang.agirise.cn.conf`

### 3.2 服务工作空间
```text
/data/workspace/n8n/
├── docker-compose.yml   # 官方标准编排文件 (涵盖 sandbox-certs, sandbox-api, sandbox-runner-1, n8n, runners)
├── .env                # 安全配置、加密密钥与沙箱通信凭证 (600 权限)
├── upgrade.sh          # 一键平滑升级运维脚本
└── data/               # n8n 工作流与本地数据库持久化目录 (属主 1000:1000)
```

---

## 4. 日常运维与一键平滑升级

### 4.1 日常运维指令
```bash
# 查看全栈容器运行状态
docker compose -f /data/workspace/n8n/docker-compose.yml ps

# 查看 n8n 主服务实时日志
docker compose -f /data/workspace/n8n/docker-compose.yml logs -f --tail 100 n8n

# 重启整套沙箱集群
docker compose -f /data/workspace/n8n/docker-compose.yml restart

# 重新加载 OpenResty 配置
systemctl reload openresty
```

### 4.2 一键升级运维操作
当官方发布新版本镜像时，执行以下命令即可实现无人值守、零配置的平滑升级：
```bash
bash /data/workspace/n8n/upgrade.sh
```
该脚本会自动拉取最新镜像、按照依赖链有序重启服务，并自动保留所有历史数据与工作流。
