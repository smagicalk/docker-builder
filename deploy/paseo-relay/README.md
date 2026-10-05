# Paseo Relay（上游服务）

上游 [`getpaseo/paseo-relay`](https://github.com/getpaseo/paseo-relay)：Paseo 的**分布式中继**
（Elixir/OTP 写的 WebSocket 中继）。镜像由本仓库自动构建：`ghcr.io/smagicalk/paseo-relay`
（跟上游 **main 分支 HEAD**，见[仓库根 README](../../README.md)）。

| 子目录 | 内容 | 说明 |
|---|---|---|
| `docker-compose.yml` | 用**预构建镜像**跑**单节点** | 一条命令起，适合单机 / 试跑 |
| `k8s/` | Kubernetes 清单（headless Service + Deployment + Service + 注释版 HTTPRoute） | 见 [`k8s/README.md`](k8s/README.md) |

> 这里只管**中继服务端**本身；Paseo 的客户端 / 被管理端不在这份清单里。

## 它需要什么

**什么都不需要**：没有数据库、没有 Redis、没有卷、没有外部依赖 —— 状态在**节点内存**里
（`syn` 做进程注册表、DNS 做节点发现）。唯一的外部条件就是：**客户端能通过 HTTP/WebSocket
连到 4000 端口**。

| 项 | 值 |
|---|---|
| 监听 | `0.0.0.0:4000`（`PASEO_RELAY_HOST` / `PASEO_RELAY_PORT` 可覆盖） |
| 存活 | `GET /health` —— 只证明 HTTP 进程活着 |
| 就绪 | `GET /ready` —— 正在 drain 或**低于 cluster floor** 时返回 `503 {"status":"unready"}` |
| 指标 | `GET /metrics`（Prometheus） |
| 单节点上限 | 默认每节点 **2 万条** WebSocket（`PASEO_RELAY_ACCEPTORS` 100 × `PASEO_RELAY_CONNECTIONS_PER_ACCEPTOR` 200） |
| 许可 | Apache-2.0 |

## 跑法一：Docker（单节点）

```bash
docker compose -f deploy/paseo-relay/docker-compose.yml up -d
curl -s http://127.0.0.1:4000/ready      # {"status":"ready"}
```

## 跑法二：Kubernetes

见 [`k8s/README.md`](k8s/README.md)（含**组网契约**、单副本 vs 多副本的关键差别、探针、
容量参数、常见坑）。

## 组网契约（多节点才用得上）

节点之间只用 **OTP 分布 + DNS 发现**，没有任何外部协调服务。这几件事必须对上：

| 变量 | 作用 | 本仓库清单里的值 |
|---|---|---|
| `RELEASE_DISTRIBUTION` | 用长节点名（`name@host`） | `name` |
| `RELEASE_NODE` | 每个实例**唯一**的节点名 | `paseo_relay@<Pod IP>`（k8s 用 `status.podIP` 展开） |
| `RELEASE_COOKIE` | 集群共享密钥，**各实例必须一致** | 从 Secret 读（不进清单） |
| `PASEO_RELAY_CLUSTER_QUERY` | 用 DNS 发现对端 | headless Service 的 FQDN |
| `PASEO_RELAY_MIN_CLUSTER_SIZE` | 低于这个节点数就报 not-ready | 单副本 `1`；扩到 N 就填 N |
| `PASEO_RELAY_OWNERSHIP_TARGET` | 本实例对外公布的「我是谁」（不透明字符串） | `instance=<Pod 名>` |

**本地实测过**（两个容器 + 共享 DNS 别名 ≈ k8s 的 headless Service）：`MIN_CLUSTER_SIZE=2` 时
两节点 `/ready` 都返回 `200 {"status":"ready"}`，日志里能看到对端 `nodeup` / `discover_request` ——
也就是说这套变量确实能把集群组起来。

## 单副本 vs 多副本（重要）

中继的**路由归属**是每节点内存里的（`syn`）：某个 session 的 owner 在哪台，后续连接就必须落到
那台。非 owner 节点收到 WebSocket 升级请求时会返回 **`409`** + 一个 reroute 头（默认
`x-reroute-target`，上游的 Fly 适配层用 `fly-replay`），**由部署方的代理把请求重放到 owner**
（上游原话：*a deployment adapter reroutes WebSocket upgrades to the owning node*）。

- **单副本**：不存在跨节点，永远不会 409 —— 本仓库的 K8s 清单默认就是 `replicas: 1`。
- **多副本**：K8s 里**没有**现成的这种适配器（Istio / Envoy、ingress-nginx 都不会「读响应头再把
  升级请求重放到指定实例」）。要么自己在网关层实现（读 409 + 那个头，再重放），要么让客户端能直连
  owner —— `PASEO_RELAY_OWNERSHIP_TARGET=instance=<Pod 名>` 正好能在 headless Service 里解析成
  Pod IP，方便你做这件事。没解决就扩副本 = 客户端会间歇性收到 409。

## 与上游 Fly 部署的对应关系

上游自己的部署在 `deployment/fly/`，可以逐条对照（我们的清单就是照它翻译的）：

| 上游 Fly | 本仓库 |
|---|---|
| `entrypoint.sh` 设 `RELEASE_NODE=paseo_relay@${FLY_PRIVATE_IP}` | 设 `RELEASE_NODE=paseo_relay@$(POD_IP)`（`status.podIP`） |
| `RELEASE_COOKIE` 用 `fly secrets set` | 从 Secret `paseo-relay-secret` 的 `release-cookie` 读 |
| `PASEO_RELAY_CLUSTER_QUERY=${FLY_APP_NAME}.internal` | headless Service 的 FQDN |
| `PASEO_RELAY_OWNERSHIP_TARGET=instance=${FLY_MACHINE_ID}` | `instance=$(POD_NAME)` |
| `PASEO_RELAY_REROUTE_HEADER=fly-replay`（Fly 专有代理） | 保持默认 `x-reroute-target`（k8s 里没有对应代理，见上一节） |
| `ELIXIR_ERL_OPTIONS=+fnu`、`ulimit -n 100000` | 环境变量 + compose 的 `ulimits` |
| `[[vm]] 1 CPU / 2GB`、`kill_timeout=30s`、`/ready` 每 10s | `resources`、`terminationGracePeriodSeconds: 30`、readiness 探针 |
