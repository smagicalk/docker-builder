# Kubernetes 部署清单（Agents-Anywhere）

**只看这个目录 + 上一层 [`../README.md`](../README.md)，就能把整套服务在 K8s 里跑起来。**

三个工作负载，各一个 Deployment + Service，一个独立命名空间 `agents-anywhere`：

| 工作负载 | 镜像 | 端口 | 持久卷（挂载点） | 副本 |
|---|---|---|---|---|
| `server` | `ghcr.io/smagicalk/agents-anywhere:latest`（**本仓库自动构建**） | 8000 | `/data`：上传 / 附件 | 1 |
| `postgres` | `postgres:17-alpine`（官方） | 5432 | `/var/lib/postgresql/data` | 1 |
| `redis` | `redis:8-alpine`（官方） | 6379 | `/data`：AOF | 1 |

跑的就是上游 `docker/docker-compose.postgres.yml` 那一套（同样的镜像、同样的参数、同样的
「先迁移再起服务」顺序），只是把一次性迁移容器换成 **init 容器**、把 named volume 换成
**hostPath 静态 PV**（你的集群没有默认 StorageClass，见「换成 NFS / 云盘」）。

> 被管理的机器上要装的是 connector（上游的 `docker/Dockerfile.connector-*`），**不属于这份
> 清单**；它用 `AGENT_SERVER_URL` 指向本服务的对外地址（K8s 里就是下面的 Ingress 域名）。

## 关键设计一览

| 点 | 做法 | 为什么 |
|---|---|---|
| 服务端策略 | `strategy: Recreate`（**不是** RollingUpdate） | 上游明说：**不同版本的写者绝不可同时**跑同一个库。滚动更新会让新旧 Pod 并存几秒 —— 正是它警告的情况；Recreate 先把旧 Pod 停干净再起新的 |
| 数据库迁移 | init 容器 `migrate` | 对应上游 compose 的 `migrate-next` 服务，**命令逐字一致**（`cd /app/server && uv run --no-sync python -m agent_server.infra.db.migrations upgrade`）；跑完才起服务。迁移本身是幂等的，只应用还没应用的那部分 |
| 等数据库 | init 容器 `wait-for-postgres` | 顶掉 compose 的 `depends_on: service_healthy`。用镜像自带的 python3 做 TCP 探测（不依赖 psql/nc）；120 秒等不到就失败退出，让 Pod 重来 —— 好过永远挂着 |
| 探针分工 | startup / liveness 打 `/api/v2/health/live`；readiness 打 `/api/v2/health/ready` | `ready` 在数据库、Redis 或实时订阅不通时返回 **503** —— 拿它当 liveness 会把「依赖挂了」变成「不停重启」。`live` 只表示进程活着 |
| 数据库密码 | Secret 里只存一份，URL 用 `$(POSTGRES_PASSWORD)` 展开拼 | 同一份密码不在清单里出现两遍，日后不会两边漂移。**必须是 hex**：`AGENT_SERVER_DB_URL` 是拼字符串拼出来的，密码里含 `@ : /` 会把这个 URL 拆坏（`$(VAR)` 展开只做文本替换，不做 URL 转义） |
| postgres / redis | **不设** `runAsNonRoot` | 这两个官方镜像的入口脚本要先以 root 把数据目录属主改成 postgres/redis 再降权启动，强制非 root 会直接起不来 |
| server 容器 | `allowPrivilegeEscalation: false` + `drop: [ALL]` | 镜像本身以 root 运行（上游 Dockerfile 没有 `USER`，标签里也没有），但它只需要监听 8000 与读写 `/data`，不需要任何提权 |
| Redis 参数 | 照抄上游：`--save "" --appendonly yes --appendfsync everysec --maxmemory 256mb --maxmemory-policy noeviction` | 那些 Timeline / 序号 key **没有 TTL**，被驱逐就是丢数据 —— 所以驱逐策略必须是 `noeviction`，持久化只靠 AOF，`/data` 必须是真的持久卷。**别改这几项** |
| Redis ACL | 用官方镜像的默认用户 | 上游要求 Redis 侧允许 `INFO server`（每条高频 upsert 都要读它拿 `run_id`）；默认用户拥有全部命令，所以这里不用建 ACL |
| Web 控制台 | 清单里**什么都不用设** | 镜像自带 `AGENT_SERVER_STATIC_DIR=/app/web-static`（静态导出的前端）与 `AGENT_SERVER_HOST=0.0.0.0`；控制台与 API **同源**：前端 `/`、API `/api/v2` |
| 对外地址 | `AGENT_SERVER_PUBLIC_ORIGIN` / `AGENT_SERVER_CORS_ORIGINS` 在清单里是**注释** | 同源部署不需要 CORS；但反代后面 **OAuth 回调**需要正确的对外地址 —— 用域名访问时把 `PUBLIC_ORIGIN` 那行取消注释 |

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `agents-anywhere`（PV 的 `claimRef` 依赖它） |
| `10-postgres.yaml` | PV + PVC（5Gi）+ Deployment + Service |
| `20-redis.yaml` | PV + PVC（1Gi）+ Deployment + Service |
| `30-server.yaml` | PV + PVC（5Gi）+ Deployment（2 个 init 容器）+ Service +（注释掉的）Ingress |

```bash
# 1) 命名空间（Secret 是命名空间级的，必须在拉 Pod 之前就位）
kubectl apply -f deploy/agents-anywhere/k8s/00-namespace.yaml

# 2) 两个密钥。**刻意不放进清单**：放进去每次 apply 都会用占位值把真密钥覆盖回去。
#    两个值都用 hex（只含 0-9a-f）—— 原因见上面「数据库密码」那一行。
kubectl -n agents-anywhere create secret generic agents-anywhere-secret \
  --from-literal=postgres-password="$(openssl rand -hex 32)" \
  --from-literal=agent-server-secret="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) 其余（`apply -f 目录` 会按文件名顺序处理）
kubectl apply -f deploy/agents-anywhere/k8s/
kubectl -n agents-anywhere rollout status deploy/postgres
kubectl -n agents-anywhere rollout status deploy/redis
kubectl -n agents-anywhere rollout status deploy/server
```

> PowerShell 里 `"$(openssl rand -hex 32)"` 跑不通（那是 bash 的写法）：先
> `$p = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })` 生成，
> 或用 WSL/Git Bash 执行上面这段。

## 存储对应表

三块盘都是 `hostPath` + `Retain`（删 PVC 不删数据），路径固定，一眼对得上：

| PV / PVC | 宿主机路径 | 挂载点 | 里面是什么 | 丢了会怎样 |
|---|---|---|---|---|
| `agents-anywhere-postgres`（5Gi） | `/srv/agents-anywhere/postgres` | postgres 的 `/var/lib/postgresql/data` | **全部事实来源**：账号、会话、Timeline、审计 | 数据全丢 —— 最该备份的一块 |
| `agents-anywhere-redis`（1Gi） | `/srv/agents-anywhere/redis` | redis 的 `/data` | AOF：已接受但还没落库的 Timeline 写入、序号头、分布式锁、短期 WebSocket 票据 | 序号可能留**空洞**，但已分配的值不会被重用（水位存在 PostgreSQL 里）；最近一次未 fsync 的写入会丢 |
| `agents-anywhere-files`（5Gi） | `/srv/agents-anywhere/files` | server 的 `/data` | 上传与附件（`AGENT_SERVER_FILES_BACKEND=local`） | 附件没了，库还在 |

## 初始化引导（空库首启）

数据库为空（`users` 表没有行）时，服务端会打印一个**一次性引导 token**；建第一个管理员必须
带上它（`/auth/register` 的引导分支要求这个 token —— 上游的设计是「谁能读服务端日志，谁才是
唯一能建首管理员的人」）：

```bash
kubectl -n agents-anywhere logs deploy/server | grep 'setup-token'
#   Paste this token into the setup page to create the admin:
#     setup-token: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   Expired? A new token is generated automatically — re-check this log.
```

然后浏览器打开控制台（见「验证」或「对外暴露」），用这个 token 建管理员。

- **有效期 15 分钟**（`AGENT_SERVER_SETUP_TOKEN_TTL` 可改，最小 60 秒）。过期后下一次访问会
  自动换一个新 token 并**重新打到日志里** —— 再看一眼日志即可。管理员建好之后 token 立即作废。
- token 是**进程内**的，所以上游明确要求：**空库的首次引导用单 worker 完成**
  （原话：*the initial setup token remains process-local*）。本清单默认就是单 worker，
  **别在引导完成前改**；Pod 重启会换一个新 token（不是坏了），照着上面再看一次日志就行。
- 想开多 worker / 多副本：先完成引导，再看「扩 worker」。

## 验证

```bash
# ① 端口转发，浏览器打开 http://127.0.0.1:5174
kubectl -n agents-anywhere port-forward svc/server 5174:8000

# ② 命令行看健康（另开一个终端）
kubectl -n agents-anywhere port-forward svc/server 8000:8000
curl -s http://127.0.0.1:8000/api/v2/health/live     # 进程活着：{"status":"ok","version":...}
curl -s http://127.0.0.1:8000/api/v2/health/ready    # 依赖都通才 200；否则 503
```

`/api/v2/health/ready` 的响应里带 `checks.database` / `checks.redis` / `checks.realtime`，
排障时看它比看 Pod 状态快（`503` 时哪一项是 `error` 就是哪一项挂了）。

## 对外暴露（Ingress）

`30-server.yaml` 尾部有一份**注释掉的 Ingress 示例**：取消注释、把域名换成你的即可。四点注意：

- **必须配 TLS**：这东西管着你的 agent、凭据与会话。上游原话：生产环境要在 Web 服务前面放 HTTPS。
- **上传**：nginx-ingress 默认 `proxy-body-size: 1m`，稍大一点的文件就被挡（示例里给到 512m）。
- **长连接**：源码里有客户端 WebSocket 通道（`client_ws`）与仪表盘的流式推送
  （`dashboard_stream`）—— nginx-ingress 默认支持 WebSocket，流式那条要**关掉缓冲**
  （`proxy-buffering: "off"`），超时也放宽（示例里是 300 秒）。
- 用域名访问后请打开清单里注释掉的 `AGENT_SERVER_PUBLIC_ORIGIN`，填 `https://你的域名` ——
  否则 **OAuth 回调**会指向容器内部的地址。

## 升级

```bash
kubectl -n agents-anywhere rollout restart deploy/server
```

`imagePullPolicy: Always`，重启即拉最新镜像（本仓库每 6 小时检查上游是否有新 release，
有新 release 才构建，见[流水线](../../../.github/workflows/agents-anywhere.yml)）。

**升级要点**（上游明确写的两条，别跳过）：

1. **不同版本的写者绝不可同时跑同一个库** —— 正确顺序是「停旧 → 备份 → 迁移 → 只起新」。
   本清单的 `strategy: Recreate` 正好就是这个顺序，所以**别改成 RollingUpdate**、**别把
   `replicas` 调大**。另外：如果你还有别的服务端在跑（另一个 compose 项目、另一台机器上的旧
   版本），升级前**先把它停掉** —— 上游原话是 `migrate-next` 的启动顺序**拦不住**另一个
   compose 项目或外部 Server。
2. **大版本迁移可能锁表**：例如 `v2.24` 把会话与 Timeline 的序号列从 `int4` 扩到 `int8`，
   这些 `ALTER TABLE` 在 PostgreSQL 上可能拿强锁、甚至重写表或索引 —— 生产要**留维护窗口**，
   并在等规模的副本上**先演练**、量一下锁与耗时。而且**迁移是前向的**：正常流量会立刻把
   revision lease 推到达标的序列前面，除非你验证过降级检查，否则不要指望回滚。

也就是说：`migrate` 这个 init 容器**不等于「升级无感」**。要稳妥就照上面的顺序手工来：

```bash
# ① 停写者（Recreate 会把它停掉，但手工升级时你先手动停更清楚）
kubectl -n agents-anywhere scale deploy/server --replicas=0

# ② 备份（必须！）
kubectl -n agents-anywhere exec deploy/postgres -- \
  pg_dump -U agents_anywhere -d agents_anywhere -Fc -f /tmp/backup.dump
kubectl -n agents-anywhere cp "$(kubectl -n agents-anywhere get pod -l app.kubernetes.io/name=postgres -o name | head -1)":/tmp/backup.dump ./backup.dump

# ③ 应用新清单 → 看迁移日志 → 起服务
kubectl apply -f deploy/agents-anywhere/k8s/
kubectl -n agents-anywhere logs deploy/server -c migrate -f
kubectl -n agents-anywhere scale deploy/server --replicas=1
```

> **别用 `kubectl exec … > backup.dump` 直接重定向**：Windows PowerShell 5.1 的 `>` 会把
> 二进制按 UTF-16 重编码，dump 出来是坏的。用上面的 `-f /tmp/…` + `kubectl cp`（走 API，
> 不经过控制台编码）。`kubectl cp` 依赖容器里有 `tar`；要是报
> `exec: "tar": executable file not found`，就先照 ① 停掉 Postgres，再直接备份宿主机目录
> `/srv/agents-anywhere/postgres`。

恢复（同样要**先停写者**）：

```bash
kubectl -n agents-anywhere scale deploy/server --replicas=0
kubectl -n agents-anywhere cp ./backup.dump "$(kubectl -n agents-anywhere get pod -l app.kubernetes.io/name=postgres -o name | head -1)":/tmp/backup.dump
kubectl -n agents-anywhere exec deploy/postgres -- \
  pg_restore -U agents_anywhere -d agents_anywhere --clean --if-exists /tmp/backup.dump
kubectl -n agents-anywhere scale deploy/server --replicas=1
```

## 换密码 / 换密钥

```bash
kubectl -n agents-anywhere create secret generic agents-anywhere-secret \
  --from-literal=postgres-password="$(openssl rand -hex 32)" \
  --from-literal=agent-server-secret="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

- `agent-server-secret` 是**会话签名密钥**：换掉 = 所有已登录会话失效（数据不受影响）。
- `postgres-password` **改 Secret 不会自动改库里的密码** —— `POSTGRES_PASSWORD` 只在数据目录
  为空时的 `initdb` 里用过一次。改了 Secret 还得同时改库里的用户密码，否则 server 报
  `password authentication failed`：

  ```bash
  kubectl -n agents-anywhere exec -i deploy/postgres -- \
    psql -U agents_anywhere -d agents_anywhere -c "ALTER USER agents_anywhere PASSWORD '新的hex密码'"
  ```

- 改完密码/密钥后：`kubectl -n agents-anywhere rollout restart deploy/server`
  （Postgres 与 Redis 本身不用重启）。

## 多节点集群：hostPath 必须钉节点

`hostPath` 的数据只存在于**一个节点**上，而 Pod 可以调度到任何节点。落到没有数据的那台时：

- `postgres` 看到的是**空目录**，于是 `initdb` **新建一个空库**（不是报错！）；
- server 起在空库上 → 又回到「空库首启」：日志里重新冒出 `setup-token`，界面变成「还没有管理员」。

数据其实好好地在另一台上 —— 但你没意识到的话，很容易在一个空库上重新开始。多节点集群二选一：

**① 钉节点**（最小改动）：给三块 PV 都加 `nodeAffinity`，值填 `kubectl get nodes` 里的 `NAME`，
**三块必须是同一台**（钉到不同节点会让 Pod 永远 `Pending`）；同时保证
`/srv/agents-anywhere/{postgres,redis,files}` 都落在那一台上：

```yaml
spec:
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["有数据的那台节点名"]
```

**② 换 CSI 存储**（推荐做法）：见下一节。

> 这跟 [`../../workbuddy/k8s/README.md`](../../workbuddy/k8s/README.md) 里的那一节是同一个坑，
> 只是这里的三块盘里有一块是数据库 —— 后果更重（空库看起来「全新可用」）。

## 换成 NFS / 云盘（动态供给）

默认 `hostPath` 最省事，但数据绑在节点上。本清单的 PV 是给**没有默认 StorageClass** 的集群
写的（`kubectl get sc` 为空时静态供给最直接）。有 CSI 之后，更省事的做法是**把三个 PV 全删
掉**、给三个 PVC 填上 `storageClassName`（并删掉 `storageClassName: ""`），让它们走动态供给 ——
Pod 从此可以调度到任意节点。

服务端的 `/data`（上传）用的是 `ReadWriteOnce`，单 Pod 下够用。真要开**多副本**时这块要换成
**RWX**（NFS / 云盘 RWX），或者把文件后端换成对象存储（`AGENT_SERVER_FILES_BACKEND`）。

## 扩 worker（先完成引导）

**先完成引导**（空库 + 单 worker 建出管理员），再谈扩容。扩容是几件事一起改：

| 改什么 | 值 | 为什么 |
|---|---|---|
| `AGENT_SERVER_WORKERS` | 例如 `4` | 多 Uvicorn worker |
| `AGENT_SERVER_TIMELINE_SINGLE_INSTANCE` | `false` | 多 worker 时**必须**关掉「单实例 Timeline 捷径」，否则 `process_settings.validate_shared_state` 直接拒绝启动 |
| `AGENT_SERVER_REDIS_URL` | 已配 | 多 worker 没有 Redis 也**直接拒绝启动**（这是刻意的） |
| Postgres `max_connections` | 跟着池子提 | 每个 worker 的连接池是 `AGENT_SERVER_DB_POOL_SIZE` + `MAX_OVERFLOW`（默认 10 + 20 = 30），而 PostgreSQL 默认只允许 **100** 条连接 |
| `/data` 上传卷 | 多副本才需要改成 RWX | 多副本必须共享上传卷，且所有实例用**同一个** `AGENT_SERVER_SECRET` |

上游给「最多 8 CPU 机器」的参考档（`docker/docker-compose.8cpu.yml`）是：
`AGENT_SERVER_WORKERS=4`、`AGENT_SERVER_EVENT_WORKERS=1`、`TIMELINE_SINGLE_INSTANCE=false`、
事件预算 16 个任务 / 16 MiB，**同时把 Postgres 的 `max_connections` 提到 200**
（连接池保持 10+20/worker → 4 个 worker 最多 120 条连接）。

> **多副本（`replicas: 2`）不是「开个开关」**：还要共享上传卷、同一个签名密钥，而且上游把
> 这套服务当「一套部署一个写者集群」用 —— 目前**没有**官方推荐的多副本配置。保守做法是
> **纵向**扩 worker（改上面几项 + 提 PG 连接数），而不是横向加 Pod。

## 常见坑

| 现象 | 原因 |
|---|---|
| `server` 卡在 `Init:0/1`，日志 `[init] 等 Postgres 超过 120 秒，放弃` | Postgres 没起来/没 Ready：`kubectl -n agents-anywhere logs deploy/postgres`；也可能是 PVC 没绑上（见下一条） |
| Pod `Pending`，事件说 `unbound Immediate PersistentVolumeClaims` | PV/PVC 绑不上：`claimRef.namespace` 写错，或 PV 与 PVC 的 `storageClassName` 不一致（静态供给时两边必须**同时**是空字符串） |
| Pod `CreateContainerConfigError` | 少了 Secret：`kubectl -n agents-anywhere get secret agents-anywhere-secret`（两个键 `postgres-password` / `agent-server-secret` 都要有），且必须在 apply 之前建好 |
| server 日志 `password authentication failed` | Secret 里的密码与库里的不一致 —— `POSTGRES_PASSWORD` 只在**空数据目录**的 `initdb` 时用过一次，之后改 Secret 不会改库里的密码，要 `ALTER USER`（见「换密码」） |
| server 报 URL/DSN 解析错误 | 密码里有 `@ : /` 之类字符。`AGENT_SERVER_DB_URL` 是拼字符串拼出来的，只许用 hex |
| 日志里反复出现新的 `setup-token` | 库还是空的（`users` 表没有行）→ 每次 Pod 重启都会重新生成。**不是坏了**，是还没完成引导；另外别把 Pod 反复重启（token 是进程内的，重启就换） |
| 界面能打开但上传报 413 | Ingress 的 `proxy-body-size` 太小（默认 1m），见「对外暴露」 |
| 仪表盘/日志流卡住、半天没新内容 | 反代缓冲没关：`proxy-buffering: "off"` |
| 浏览器报 CORS 错 | 你把前端放到了**另一个域名**。同源部署（本清单默认）不需要 CORS；跨源时才设 `AGENT_SERVER_CORS_ORIGINS`（或用 `AGENT_SERVER_CORS_ORIGIN_REGEX` 放行） |
| OAuth 登录回调跳到 `127.0.0.1` 之类 | `AGENT_SERVER_PUBLIC_ORIGIN` 没设成对外域名（反代后面必须设） |
| 改了 `AGENT_SERVER_WORKERS` 后起不来，日志说多 worker 需要 Redis / 要关 single-instance | 见「扩 worker」：多 worker 必须配 Redis 且 `AGENT_SERVER_TIMELINE_SINGLE_INSTANCE=false`；被拒绝启动是**刻意**的保护 |
| Redis 报写入被拒 / `OOM command not allowed` | `noeviction` 到达 `maxmemory` 后会**拒绝写**而不是驱逐（那些 key 没有 TTL，驱逐等于丢数据）。要么调大 `--maxmemory`（同时调大内存 limit），要么清理不再需要的会话 |
| `migrate` init 容器失败 | 看它自己的日志：`kubectl -n agents-anywhere logs deploy/server -c migrate`（迁移用 PostgreSQL 会话级咨询锁串行化，等不到锁会超时，超时上限由 `AGENT_SERVER_MIGRATION_LOCK_TIMEOUT` 控制，本清单是 120 秒） |
| 宿主机目录属主不对、postgres 报 `data directory has wrong ownership` | `/srv/agents-anywhere/{postgres,redis}` 是别的用户建的：`chown -R 999:999 /srv/agents-anywhere/postgres`（postgres 容器内 uid 999）、Redis 同理（容器内 redis 用户） |

## 与上游 compose 的对应关系

| 上游 `docker/docker-compose.postgres.yml` | 本清单 |
|---|---|
| `postgres-next`（`postgres:17-alpine` + named volume + `pg_isready` healthcheck） | `10-postgres.yaml`：同一个镜像、同一句 healthcheck（改成探针），卷换成 PVC |
| `redis-next`（`redis:8-alpine` + 那条 `command` + named volume + `redis-cli ping`） | `20-redis.yaml`：同一个镜像、同一条 `command`（逐条对应），卷换成 PVC |
| `migrate-next`（一次性服务，`depends_on: postgres service_healthy`，命令 + `AGENT_SERVER_MIGRATION_LOCK_TIMEOUT`） | init 容器 `migrate`（命令逐字一致、锁超时同样是 120 秒）+ `wait-for-postgres` 顶掉 `depends_on` |
| `server-next`（`depends_on: migrate completed_successfully` + 一整套 env + `/data` 卷） | `30-server.yaml` 的主容器（env 与它同一套默认值：池 10/20/30/1800、Redis 连接超时 5、序号租约 4096、文件后端 local） |
| `${AGENTS_ANYWHERE_WEB_PORT:-5174}:8000` | Service `server` 的 8000 + Ingress（或 `port-forward 5174:8000`） |
| `AGENT_SERVER_CORS_ORIGINS` 默认 `http://127.0.0.1:5174,http://localhost:5174` | 注释掉 —— 同源部署不需要 CORS，要跨源时再打开 |
| （镜像自带的 env） | 清单里**没有**重复设 `AGENT_SERVER_STATIC_DIR` / `AGENT_SERVER_DB_BACKEND`（后端显式设了）/ `AGENT_SERVER_HOST`（显式设了一遍防被镜像默认值坑到） |

三个**别改**的值：库名与用户名都叫 `agents_anywhere`（URL 与 `pg_isready` 都写死了它）、
`AGENT_SERVER_FILES_LOCAL_ROOT=/data/agent-server.files`（换成别的路径就与镜像里的 `VOLUME /data`
脱节）、Redis 那条 `command`。
