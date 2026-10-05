# Kubernetes 部署清单（Paseo Relay）

**只看这个目录 + 上一层 [`../README.md`](../README.md)，就能把中继跑起来。**

集群里只有三个对象，而且**没有任何存储**：

| 对象 | 作用 |
|---|---|
| Deployment `paseo-relay` | 中继本体（默认 **1 副本**） |
| Service `paseo-relay-headless` | 给**节点发现**用（`clusterIP: None`，DNS 返回所有 Pod IP） |
| Service `paseo-relay` | 给客户端 / 网关用的入口（ClusterIP 4000） |

状态全在**节点内存**里（`syn` 做进程注册表）：没有库、没有 Redis、没有卷 —— Pod 重启即丢，
客户端重连即可。所以这份清单里没有 PV/PVC、没有 init 容器。

## 关键设计一览

| 点 | 做法 | 为什么 |
|---|---|---|
| 副本数 | 默认 `replicas: 1` | 「归属」是每节点内存态：某 session 的 owner 在哪台，后续连接就必须落到那台。跨节点要靠**代理把 409 + reroute 头重放**，k8s 里没有现成适配器 → 单副本永远不会 409。扩副本见「扩容」 |
| 节点发现 | headless Service + **`publishNotReadyAddresses: true`** | DNSCluster 查这个名字拿到**所有** Pod IP。不加这一项会**死锁**：Pod 未 Ready 就默认不在 DNS 里，而「Ready」又要求达到 cluster floor —— 两副本同时启动会互相看不到 |
| 节点身份 | `RELEASE_NODE=paseo_relay@$(POD_IP)`（`status.podIP`） | 每个实例必须唯一；与上游 Fly 适配层同一套（它用实例私有 IP），所以 `PASEO_RELAY_CLUSTER_QUERY` 解析出来的 IP 正好能对上节点名 |
| 集群密钥 | `RELEASE_COOKIE` 从 Secret 读 | Erlang 集群共享密钥，**各副本必须完全一致**，否则节点连不上（表现：`/ready` 一直 503、日志里没有对端 `nodeup`） |
| 探针分工 | readiness 打 `/ready`，startup/liveness 打 `/health` | `/ready` 在 draining、**低于 cluster floor**、容量或内存压力时返回 503；`/health` 只证明 HTTP 进程活着。拿 `/ready` 当 liveness 会把「集群没组起来」变成重启风暴 |
| cluster floor | `PASEO_RELAY_MIN_CLUSTER_SIZE`（默认 `1`） | 低于它就报 not-ready。**扩副本时必须同步改大**，否则新节点在集群没组好时就对外接活 |
| 优雅停机 | `terminationGracePeriodSeconds: 30` + `preStop: sleep 5` | 与上游 Fly 的 `kill_timeout = 30s` 对齐；preStop 先让客户端端点摘掉再收尾 |
| 滚动更新 | `maxUnavailable: 0` + `maxSurge: 1` | 多副本时一次只换一个，别把 cluster floor 瞬间打穿 |
| 资源 | requests 250m/512Mi、limits 1/2Gi | 与上游 Fly 机型一致（1 性能核 / 2GB）。默认容量上限是**每节点 2 万条** WebSocket，内存随流量涨 |
| fd 上限 | 清单里不用配 | 上游 Fly 适配层要 `ulimit -n 100000`（每条 WebSocket 一个 socket）；k8s 里容器运行时给的上限通常已是百万级，够用 |
| locale | `LANG=C.UTF-8` + `ELIXIR_ERL_OPTIONS=+fnu` | 镜像运行时基础层没设 locale，不设这两项启动会警告 latin1 |
| 对外暴露 | 注释版 HTTPRoute，`timeouts: 0s` | WebSocket 是长连接，网关默认超时（Envoy 的 route timeout 默认 15 秒）会把它掐断 |

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `paseo-relay` |
| `10-relay.yaml` | headless Service + Deployment + Service +（注释掉的）HTTPRoute |

```bash
# 1) 命名空间
kubectl apply -f deploy/paseo-relay/k8s/00-namespace.yaml

# 2) 集群共享密钥（**刻意不放进清单**：放进去每次 apply 都会用占位值覆盖真值）
kubectl -n paseo-relay create secret generic paseo-relay-secret \
  --from-literal=release-cookie="$(openssl rand -base64 48)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) 其余
kubectl apply -f deploy/paseo-relay/k8s/10-relay.yaml
kubectl -n paseo-relay rollout status deploy/paseo-relay
```

> PowerShell 里 `"$(openssl rand -base64 48)"` 跑不通（那是 bash 的写法）：用 WSL/Git Bash
> 执行这段，或者用 `[Convert]::ToBase64String((1..48 | ForEach-Object { Get-Random -Max 256 }))` 自己生成。

## 验证

```bash
# ① 端口转发，看就绪与指标
kubectl -n paseo-relay port-forward svc/paseo-relay 4000:4000
curl -s http://127.0.0.1:4000/ready      # {"status":"ready"}
curl -s http://127.0.0.1:4000/metrics | grep -E '^paseo_relay_(ready|draining|active_websockets|active_sessions) '

# ② 集群内确认节点发现用的 DNS 能解析（单副本时它解析到自己）
kubectl -n paseo-relay exec deploy/paseo-relay -- \
  getent hosts paseo-relay-headless.paseo-relay.svc.cluster.local
```

`/ready` 的两种失败形态要分清：**503 `{"status":"unready"}`** 是应用自己说「我现在不接活」
（draining / 没到 cluster floor / 容量或内存压力）；而探针超时（`context deadline exceeded`）是
网络或负载问题 —— 清单里 readiness 给了 `timeoutSeconds: 3`（上游的状态窗口按秒描述）。

## 扩容（多副本）

单副本已经能吃到一台机器的默认上限（每节点 2 万条 WebSocket）。要横向扩，**按这个顺序**：

1. **先解决跨节点 reroute**（见 [`../README.md`](../README.md) 的「单副本 vs 多副本」）：非 owner 节点
   会对 WebSocket 升级请求返回 **`409`** + reroute 头（默认 `x-reroute-target`），需要**你的网关**读那个头
   再把升级请求重放到 owner。k8s 里没有现成适配器 —— 没解决就扩副本，客户端会间歇性收到 409。
2. 改 `10-relay.yaml` 的 `replicas`，**同时**把 `PASEO_RELAY_MIN_CLUSTER_SIZE` 改大（一般填副本数）。
3. 观察组网：
   ```bash
   kubectl -n paseo-relay logs deploy/paseo-relay | grep -E 'nodeup|discover_request'
   ```
   看到对端节点 `nodeup` 才算组上了。`paseo_relay_active_sessions` 是**本节点**的归属数，
   各节点不同是正常的。
4. **下线某个节点**：先把它标成 draining（给它 `PASEO_RELAY_DRAIN=true` 后重启那个实例），等它的会话
   迁走再删 —— 这是上游契约里的做法（`PASEO_RELAY_DRAIN` 是**启动**开关，不是运行时热切换）。

## 容量参数（按需调，默认值来自上游）

| 变量 | 默认 | 作用 |
|---|---|---|
| `PASEO_RELAY_ACCEPTORS` | `100` | 监听 acceptor 进程数 |
| `PASEO_RELAY_CONNECTIONS_PER_ACCEPTOR` | `200` | × acceptors = 每节点活动 WebSocket 上限（默认 **20000**） |
| `PASEO_RELAY_INGRESS_BUDGET_BYTES` | `536870912`（512MiB） | 节点级「已受理消息」的加权内存预算（超了会拒绝新消息/连接） |
| `PASEO_RELAY_INGRESS_WEIGHT` | `4` | 每字节线上负载记多少内存权重（保守值） |
| `PASEO_RELAY_MEMORY_WATERMARK_BYTES` | `0`（关闭） | 超过就进入内存压力回收（会主动断连） |
| `PASEO_RELAY_DELIVERY_TIMEOUT_MS` / `PASEO_RELAY_TRANSPORT_SEND_TIMEOUT_MS` | `30000` / `35000` | 慢消费者先被应用层掐断、再兜到 TCP 层（后者必须更大） |
| `PASEO_RELAY_DRAIN` | `false` | 置 `true` 并重启 = 该节点不再接受新归属（下线前用） |

调大内存上限时记得同时调大 Pod 的 `resources.limits.memory`；观察点看 `/metrics` 里的
`paseo_relay_beam_total_memory_bytes`、`ingress_reserved_bytes`、`connection_rejections_total`。

## 常见坑

| 现象 | 原因 |
|---|---|
| `/ready` 一直 `503 {"status":"unready"}` | 三种：① 没到 cluster floor（`PASEO_RELAY_MIN_CLUSTER_SIZE` 比实际节点数大）；② `RELEASE_COOKIE` 各副本不一致；③ headless Service 解析不到对端。先看日志有没有对端 `nodeup`，再用上面那条 `getent hosts` 验 DNS |
| 客户端**间歇性**收到 `409` | 多副本但没做 reroute 适配器（非 owner 节点就是这么答的）。要么回到单副本，要么在网关层实现重放 —— 见「扩容」第 1 步 |
| Pod 一直 `0/1`，但 `/health` 明明是 200 | **正常**：`/health` 只证明进程活着，就绪看 `/ready`（见上一条） |
| 连接建立几十秒后被断开 | 网关/反代设了请求超时。HTTPRoute 里给 `timeouts: {request: 0s, backendRequest: 0s}`（或网关侧关掉），WebSocket 是长连接 |
| 滚动更新/删 Pod 时客户端集体掉线 | 预期（内存态归属随 Pod 消失），客户端会自动重连；想更平滑就调大 `terminationGracePeriodSeconds`，多副本时靠 `maxUnavailable: 0` 保住 floor |
| 启动日志里 `the VM is running with native name encoding of latin1 …` | 镜像基础层没设 locale：清单里已给 `LANG=C.UTF-8` 与 `ELIXIR_ERL_OPTIONS=+fnu`，若你删了它们就会再出现 |
| `headless` Service 查不到 Pod IP | selector 与 Pod 标签不一致、或忘了 `publishNotReadyAddresses: true`（未 Ready 的 Pod 默认不进 DNS） |
| Pod 被 OOMKilled | 流量超过内存预算：调大 `resources.limits.memory`，并按上面那张表调 `INGRESS_BUDGET_BYTES` / `MEMORY_WATERMARK_BYTES`；先看 `/metrics` 的 `beam_total_memory_bytes` 与 `ingress_reserved_bytes` |
| 重启后「会话归属全变了」 | **预期行为**：归属是内存态，没有任何持久化。客户端重连即可（这也是这套服务不需要任何卷的原因） |
