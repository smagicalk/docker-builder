# Agents-Anywhere（上游服务 + 依赖）

上游 [`anywhere-labs/Agents-Anywhere`](https://github.com/anywhere-labs/Agents-Anywhere)：
一个把「多台机器上的 agent」统一管理起来的服务端（FastAPI 后端 + 静态导出的 Web 控制台）。
镜像由本仓库自动构建：`ghcr.io/smagicalk/agents-anywhere`（见[仓库根 README](../../README.md)）。

| 子目录 | 内容 | 说明 |
|---|---|---|
| `docker-compose.yml` | 用**预构建镜像**跑：Postgres 17 + Redis 8 + 一次性迁移 + 服务端 | 与上游那份的差别只有一处 —— `build:` 换成 `image:`，不本地编译 |
| `k8s/` | Kubernetes 整套清单（Postgres / Redis / Server + 命名空间与说明） | 见 [`k8s/README.md`](k8s/README.md) |

> 连接器（`docker/Dockerfile.connector-*`、`dsh-bridge`）是给**被管理的机器**装的，不属于这份
> 服务端部署；这里只管服务端 + 它的两个依赖。

## 它需要什么

| 组件 | 镜像 | 作用 | 端口 | 持久化 |
|---|---|---|---|---|
| `server` | `ghcr.io/smagicalk/agents-anywhere`（**本仓库构建**） | FastAPI 后端 + Web 控制台（同源） | `8000`（compose 里映射到 5174） | `/data`：上传/附件（`AGENT_SERVER_FILES_BACKEND=local`） |
| `postgres` | `postgres:17-alpine` | **唯一的事实来源**（会话、Timeline 等） | `5432` | `/var/lib/postgresql/data` |
| `redis` | `redis:8-alpine` | 跨实例协调、Pub/Sub、Timeline 序号与写缓冲 | `6379` | `/data`（AOF `everysec`，**必须持久化**） |

两个外部依赖都不是可选的：上游文档写明 Redis 那些 key **没有 TTL**，所以用 AOF + 持久卷 +
`noeviction`；而 Postgres 才是最终落盘的地方。

## 跑法一：Docker

```bash
# 目录里准备一份 .env（或直接传环境变量）：
#   POSTGRES_PASSWORD=<openssl rand -hex 32>     # 用 hex，避免后面拼 DB URL 时要转义
#   AGENT_SERVER_SECRET=<openssl rand -hex 32>
POSTGRES_PASSWORD=... AGENT_SERVER_SECRET=... docker compose up -d
docker compose logs -f server     # 首次空库会打印引导 token
```

顺序与上游一致：`postgres`/`redis` 健康 → `migrate` 跑一次迁移 → `server` 起。
Web 控制台：`http://127.0.0.1:5174`。

## 跑法二：Kubernetes

见 [`k8s/README.md`](k8s/README.md)（含初始化引导、升级时的停机窗口、扩 worker 的前提）。

## 三个容易踩的点（上游文档明确写的）

1. **首次必须在空库上用单 worker 完成引导**：初始 setup token 只存在于那个进程里，日志里打印。
   想开多 worker（`AGENT_SERVER_WORKERS`，需同时 `AGENT_SERVER_TIMELINE_SINGLE_INSTANCE=false`）
   或加副本，先完成引导。
2. **升级不能新老写者并存**：上游说 `v2.23`/更早 与 `v2.24` 的写者**绝不可同时**跑同一个库 ——
   要「停旧 → 备份 → 迁移 → 只起新」。K8s 清单因此用 `strategy: Recreate`（不是滚动更新）。
3. **大版本迁移可能锁表**：`v2.24` 把会话/Timeline 的序号列从 `int4` 扩到 `int8`，`ALTER TABLE`
   可能重写表或索引 —— 生产要留维护窗口、先在等规模副本上演练。

## 许可

上游仓库**没有声明 License**（GitHub API 返回 `null`）= 默认「保留所有权利」。本仓库构建并推送的
镜像等于再分发上游代码，请自行确认使用边界；镜像标签里也记了 `upstream.license=none-declared`。
