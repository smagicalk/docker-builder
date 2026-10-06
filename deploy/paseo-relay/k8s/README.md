# Kubernetes 部署清单（Paseo Relay）

**只看这个目录 + 上一层 [`../README.md`](../README.md)，就能把中继跑起来。**

集群里只有**两个对象**，而且没有任何存储：

| 对象 | 作用 |
|---|---|
| Deployment `paseo-relay` | 中继本体（**单实例**，`replicas: 1`） |
| Service `paseo-relay` | 客户端 / 网关用的入口（ClusterIP 4000） |

状态全在**节点内存**里（`syn` 做进程注册表）：没有库、没有 Redis、没有卷 —— Pod 重启即丢，
客户端重连即可。所以这份清单里没有 PV/PVC、没有 init 容器，**也没有 Secret**。

> 这套单实例形态是**实测**过的（环境变量与本清单一致）：`/ready` 返回 `200 {"status":"ready"}`、
> `/metrics` 里 `paseo_relay_ready 1`、日志 0 条报错、**4369 无监听**（`RELEASE_DISTRIBUTION=none`
> 连 Erlang 分布都不起）。

## 关键设计一览

| 点 | 做法 | 为什么 |
|---|---|---|
| 副本数 | **固定 `replicas: 1`** | 中继的「归属」是每节点内存态：某 session 的 owner 在哪台，后续连接就得落到那台。多副本要先把节点组起来、还要网关重放 409 —— 配方见「扩容（多副本）」。**别只改这个数字** |
| Erlang 分布 | `RELEASE_DISTRIBUTION=none` | 单实例不需要节点发现 → 不起 epmd、不监听 4369、不解析集群 DNS（实测无副作用） |
| 探针分工 | readiness 打 `/ready`，startup/liveness 打 `/health` | `/ready` 是「能不能接新活」（draining、容量或内存压力时 503）；`/health` 只证明 HTTP 进程活着。拿 `/ready` 当 liveness 会把「暂时不接活」变成重启风暴 |
| 优雅停机 | `terminationGracePeriodSeconds: 30` + `preStop: sleep 5` | 与上游 Fly 的 `kill_timeout = 30s` 对齐；preStop 先让客户端端点摘掉再收尾 |
| 滚动更新 | `maxUnavailable: 0` + `maxSurge: 1` | 先起新的、再删旧的 → 换版本不出现服务空窗 |
| 资源 | requests 250m/512Mi、limits 1/2Gi | 与上游 Fly 机型一致（1 性能核 / 2GB）。默认容量上限是**每节点 2 万条** WebSocket，内存随流量涨 |
| fd 上限 | 清单里不用配 | 上游 Fly 适配层要 `ulimit -n 100000`（每条 WebSocket 一个 socket）；k8s 里容器运行时给的上限通常已是百万级 |
| locale | `LANG=C.UTF-8` + `ELIXIR_ERL_OPTIONS=+fnu` | 镜像运行时基础层没设 locale，不设会警告 latin1（上游 Fly 适配层也设了 `+fnu`） |
| 对外暴露 | 注释版 HTTPRoute，`timeouts: 0s` | WebSocket 是长连接，网关默认超时（Envoy 的 route timeout 默认 15 秒）会把它掐断 |

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `paseo-relay` |
| `10-relay.yaml` | Deployment（单实例）+ Service +（注释掉的）HTTPRoute |

```bash
kubectl apply -f deploy/paseo-relay/k8s/00-namespace.yaml
kubectl apply -f deploy/paseo-relay/k8s/10-relay.yaml
kubectl -n paseo-relay rollout status deploy/paseo-relay
```

## 验证

```bash
kubectl -n paseo-relay port-forward svc/paseo-relay 4000:4000

curl -s http://127.0.0.1:4000/ready      # {"status":"ready"}
curl -s http://127.0.0.1:4000/metrics | grep -E '^paseo_relay_(ready|draining|active_websockets|active_sessions) '
```

`/ready` 的两种失败形态要分清：**503 `{"status":"unready"}`** 是应用自己说「我现在不接活」
（draining / 容量或内存压力）；**探针超时**（`context deadline exceeded`）是网络或负载问题 ——
清单里 readiness 给了 `timeoutSeconds: 3`。

## 扩容（多副本）—— 默认不需要

单实例已经能吃满一台机器的默认上限（每节点 2 万条 WebSocket）；容量不够**先纵向**调（见下面
「容量参数」）。真要横向扩，**不要只改 `replicas`** —— 必须按下面补齐组网，否则会得到 N 个
互不相识的节点各自为政，客户端**重连**时会收到 `409`。

1. **加回节点发现**（单实例清单里刻意没有；headless Service 的 DNS 名字就是发现用的查询名）：
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: paseo-relay-headless
     namespace: paseo-relay
   spec:
     clusterIP: None
     # ⚠️ 必须为 true：Pod 未 Ready 时默认会从 DNS 里摘掉，而「Ready」又要求达到 cluster floor
     #    （PASEO_RELAY_MIN_CLUSTER_SIZE）—— 两副本同时启动会互相看不到、谁都到不了 floor，死锁。
     publishNotReadyAddresses: true
     selector:
       app.kubernetes.io/name: paseo-relay
     ports:
       - name: relay
         port: 4000
         targetPort: relay
   ```
2. **建集群共享密钥**（各副本必须完全一致，否则节点之间连不上：表现是 `/ready` 一直 503、
   日志里没有对端 `nodeup`）：
   ```bash
   kubectl -n paseo-relay create secret generic paseo-relay-secret \
     --from-literal=release-cookie="$(openssl rand -base64 48)" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. **补容器环境变量**（把 `RELEASE_DISTRIBUTION` 从 `none` 改成 `name`）：
   ```yaml
   - name: POD_IP
     valueFrom: {fieldRef: {fieldPath: status.podIP}}
   - name: POD_NAME
     valueFrom: {fieldRef: {fieldPath: metadata.name}}
   - name: RELEASE_DISTRIBUTION
     value: name
   - name: RELEASE_NODE
     value: paseo_relay@$(POD_IP)
   - name: RELEASE_COOKIE
     valueFrom: {secretKeyRef: {name: paseo-relay-secret, key: release-cookie}}
   - name: PASEO_RELAY_CLUSTER_QUERY
     value: paseo-relay-headless.paseo-relay.svc.cluster.local
   - name: PASEO_RELAY_MIN_CLUSTER_SIZE
     value: "3"          # = 副本数（或你接受的下限）
   - name: PASEO_RELAY_OWNERSHIP_TARGET
     value: instance=$(POD_NAME)
   ```
   （`POD_IP` / `POD_NAME` 必须排在用 `$(VAR)` 引用它们的变量**之前**；`RELEASE_NODE` 用 Pod IP
   是为了和 headless Service 解析出来的 IP 对上。）
4. **处理跨节点重连的 409**：非 owner 节点会对 WebSocket 升级请求返回 `409` + reroute 头
   （默认 `x-reroute-target: instance=<Pod 名>`）—— 要么在网关侧重放，要么用 Istio 重试让它概率收敛。
   **只有「重连」会撞上**（全新会话任何节点都能认领）。三种做法与取舍见
   [`../README.md`](../README.md) 的「单副本 vs 多副本」。
5. **改 `replicas`**（与 `PASEO_RELAY_MIN_CLUSTER_SIZE` 一致）。
6. **观察**：`kubectl -n paseo-relay logs deploy/paseo-relay | grep -E 'nodeup|discover_request'`
   看到对端节点才算组上了；再看 `/metrics` 的 **`paseo_relay_reroute_responses_total`**
   是否增长（增长就说明第 4 步不能省）。`paseo_relay_active_sessions` 是**本节点**的归属数，
   各节点不同属正常。
7. **下线某个节点**：先给它 `PASEO_RELAY_DRAIN=true` 后重启该实例（不再接受新归属），等会话迁走再删
   —— `PASEO_RELAY_DRAIN` 是**启动**开关，不是运行时热切换。

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
| Pod 一直 `0/1`，但 `/health` 明明是 200 | **正常**：`/health` 只证明进程活着，就绪看 `/ready` |
| `/ready` 一直 `503 {"status":"unready"}` | 单实例下先看进程日志（`kubectl -n paseo-relay logs deploy/paseo-relay`）与端口：draining 或容量/内存压力时会这么答。**如果你是扩成了多副本**，还多两种可能：没到 cluster floor（`PASEO_RELAY_MIN_CLUSTER_SIZE` 比实际节点数大）、`RELEASE_COOKIE` 各副本不一致 |
| 客户端**重连**时收到 `409` | 该会话的 owner 在别的节点（多副本 + 没做 reroute 重放）。**单实例不会**（也不会有别的节点）。判断：`/metrics` 的 `paseo_relay_reroute_responses_total` 是否增长 —— 细节见 [`../README.md`](../README.md) |
| 连接建立几十秒后被断开 | 网关/反代设了请求超时。HTTPRoute 里给 `timeouts: {request: 0s, backendRequest: 0s}`（或网关侧关掉），WebSocket 是长连接 |
| 滚动更新/删 Pod 时客户端掉线 | 预期（内存态归属随 Pod 消失），客户端会自动重连；清单已用 `maxUnavailable: 0` 先起新的再删旧的，想更平滑就调大 `terminationGracePeriodSeconds` |
| 启动日志里 `the VM is running with native name encoding of latin1 …` | 镜像基础层没设 locale：清单里已给 `LANG=C.UTF-8` 与 `ELIXIR_ERL_OPTIONS=+fnu`，删掉它们就会再出现 |
| Pod 被 OOMKilled | 流量超过内存预算：调大 `resources.limits.memory`，并按上面那张表调 `INGRESS_BUDGET_BYTES` / `MEMORY_WATERMARK_BYTES`；先看 `/metrics` 的 `beam_total_memory_bytes` 与 `ingress_reserved_bytes` |
| 重启后「会话归属全变了」 | **预期行为**：归属是内存态，没有任何持久化。客户端重连即可（这也是这套服务不需要任何卷的原因） |
| （多副本）`headless` Service 查不到 Pod IP | selector 与 Pod 标签不一致，或忘了 `publishNotReadyAddresses: true`（未 Ready 的 Pod 默认不进 DNS） |
