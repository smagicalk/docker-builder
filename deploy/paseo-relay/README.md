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

先说结论：**多节点本身没问题，会出问题的只有「重连」**。判定逻辑在 `lib/paseo_relay/ownership.ex`
与 `socket.ex`，逐条列出来：

| 情况 | 行为 |
|---|---|
| 该 serverId **还没有 owner**（全新会话） | 任何达到 cluster floor 的节点都**直接认领** → 正常建立 ✓ |
| owner 就是**本节点** | 正常 ✓ |
| owner 在**别的节点**（重连，或换 Pod 后落到别台） | 回 **`409`** + reroute 头（默认 `x-reroute-target: instance=<Pod 名>`）—— 需要部署方的代理把这次升级请求**重放**到 owner |
| owner 所在 Pod 挂了 | `syn` 注册表随之消失 → 该 serverId 回到「无 owner」→ 任何节点都能重新认领 ✓（节点故障是自愈的） |

上游自己就是靠代理重放解决的：Fly 适配层发 `fly-replay: instance=<machine-id>`，由 Fly Proxy 重放
（README 原话：*a deployment adapter reroutes WebSocket upgrades to the owning node*）。**k8s 里没有
这种代理** —— 要多副本，这一步得自己补（或依赖客户端重试，见文末那条未验证项）。

### 三个选项

| 选项 | 做法 | 代价 / 风险 |
|---|---|---|
| ① **单副本**（本清单默认） | 什么都不用做 | 没有 409；默认每节点 2 万条 WebSocket，多数场景够用 |
| ② **网关侧重放**（对齐上游） | 读 409 响应里的 `x-reroute-target`，把升级请求重放到那台。`instance=<Pod 名>` 在 headless Service 里正好能解析成 Pod IP（本清单把 target 设成 Pod 名就是为了这一步） | 要自己实现：Envoy 的 Lua / Wasmer 过滤器，或一个外部处理器 |
| ③ **让重试概率收敛**（务实降级） | Istio `VirtualService`：`retries: {attempts: 3, retriableStatusCodes: [409]}`（Istio 的重试会换 host） | 不是协议级保证，只是概率收敛；每次重试多一次往返。⚠️ k8s Service 的 `sessionAffinity: ClientIP` 在这里**无效**（流量由网关的 Envoy 直接负载均衡，不经过 kube-proxy）；要按源 IP 亲和得用 Istio `DestinationRule` 的 `consistentHash: {useSourceIp: true}` |

### 怎么判断有没有踩到

`/metrics` 里有 **`paseo_relay_reroute_responses_total`** —— 每次返回 409 都会 +1。扩副本后盯它：
**一直为 0** 说明你的客户端/拓扑没触发跨节点重连；**持续增长** 就说明需要 ② 或 ③。

> ⚠️ **两个没验证的点**（别当保证）：① 客户端收到 409 之后会不会自己重试 —— 我读的是中继代码，
> 没读 Paseo 客户端；会重试的话多副本的 409 只是多一次往返，不会就是硬失败。② 我**没有**在真实
> k8s 集群里跑过多副本，只在本机两个容器上验证了**组网**本身（`MIN_CLUSTER_SIZE=2` 时两节点
> `/ready` 都 200、日志出现对端 `nodeup`）。

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
