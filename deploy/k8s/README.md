# Kubernetes 部署清单

**只看这个目录 + 仓库根目录的 `docker-compose.yml`，就能把整套 WorkBuddy 跑起来。**

两个组件（面板 + 上游网关）是**两套独立的部署**：各带自己的 PersistentVolume、
各自的 Service、各自的 Deployment。面板**不挂上游的任何目录**，只通过 Service 走
HTTP 连过去 —— 所以两边互不等待，各自调度、各自升级重启。

| 组件 | 镜像 | 端口 | 存储 |
|---|---|---|---|
| 上游网关 | `ghcr.io/smagicalk/workbuddy2api:latest`（**本仓库自动构建**） | 7863 | 凭证 / 池状态（2 块卷，上游独享）；配置走只读 ConfigMap |
| 管理面板（入口） | `ghcr.io/ithtelab/workbuddy-manager:latest`（官方发布） | 7864 | 面板数据，1 块卷，面板独享 |

上游原仓库已不可访问，源码随 workbuddy-manager 的 Release 附件分发，
本仓库定时把它打包成镜像（见根目录 README 的「两种触发方式」）。

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `workbuddy`（PV 的 `claimRef` 依赖它） |
| `10-upstream.yaml` | 上游：2 PV + 2 PVC + ConfigMap（配置本体）+ Deployment + Service |
| `20-manager.yaml` | 面板：1 PV + 1 PVC + Deployment + Service +（注释掉的）Ingress |

```bash
kubectl apply -f deploy/k8s/      # 按文件名顺序应用
```

## 存储对应表

**配置**（`config.json`）不占卷 —— 它是只读的 ConfigMap `workbuddy2api-config`；
其余三块 PV 都是 `hostPath` + `Retain`（删 PVC 不删数据），路径固定，一眼对得上：

| PV / PVC | 存储（宿主机路径） | 挂载点 | 里面是什么 | 丢了会怎样 |
|---|---|---|---|---|
| `workbuddy2api-auths`（1Gi） | `/srv/workbuddy/upstream/auths` | 上游 `/app/auths` | 每个账号一份凭证 `workbuddy-<uid>.json` | **要重新扫码加号** —— 最该备份的一个 |
| `workbuddy2api-pool`（1Gi） | `/srv/workbuddy/upstream/pool` | 上游 `/app/data` | `state.json`（积分/冷却/熔断）、`model.json`（成本账本） | 不致命，冷却与便宜号账本要重新学 |
| `workbuddy-manager-data`（5Gi） | `/srv/workbuddy/manager/data` | 面板 `/app/data` | `manager.db`（密钥/日志/用量/审计）、`users.json`（管理员 + 会话签名密钥） | 要重新初始化管理员、已发会话全部失效、统计与审计丢失 |

每块卷都是**独享**的：面板不挂上游那两块，上游也不挂面板那块。

## 两个组件的边界（为什么加账号要在上游做）

上游既没有「加账号」的 HTTP 接口，也没有热改配置的接口 —— 面板那两项功能天生
要靠**直接读写上游的 `auths/` 与 `config.json`**（清单里后者是只读的 ConfigMap，
所以那一项在 K8s 下改用 kubectl 改 ConfigMap，见下节）。所以拆开之后：

| 面板功能 | 拆开部署后 | 替代做法 |
|---|---|---|
| 扫码「添加账号」 | ✗ **看似成功**：会写进面板容器自己的目录，上游读不到（显示「未加载」）、Pod 重启即丢 —— 清单里已用**只读空卷**把它变成硬报错 | 在上游容器里登录（见下节） |
| 「设置」页保存 | ✗ 读不到 `config.json` → 报错并锁定保存 | 改 ConfigMap + 重启上游（见下节） |
| 上游重启 / 读上游日志 / 端口收敛 / 一键更新 | ✗ 降级提示（k8s 里没有 docker 守护进程） | `kubectl -n workbuddy logs\|rollout restart ...` |
| 仪表盘、账号列表、密钥分发、请求日志、用量统计、IP 管控、模型中心、聊天测试台 | ✓ 照常（`pool_available` 会如实反映连不连得上上游） | 只走 HTTP，不受影响 |

> **为什么「添加账号」不是简单报错**（这点我实测过）：面板落盘凭证时会**自己建目录**
> —— `server/services/tencent.py` 的 `write_auth_file` 里就是
> `base.mkdir(parents=True, exist_ok=True)`；而镜像里 `/opt/workbuddy2api` 本来就存在。
> 所以什么都不挂时，它会**成功**把凭证写进面板容器自己那层临时文件系统，上游永远
> 看不到。清单因此给 `/opt/workbuddy2api` 挂了一个**只读空卷**：写入立刻拿到
> `Read-only file system`，当场暴露（已实测：不影响启动与查询）。
> **别**把它换成可写的 emptyDir 或 hostPath。
>
> 「设置」保存那条是面板自己的设计：「读失败明确报原因并锁定保存」，不会用空配置
> 覆盖真实文件。想把这四项能力全部找回来，见下面「有 RWX 存储时切回共享卷」。

## 部署

```bash
# 1) 先建命名空间 —— Secret 是命名空间级的，密钥必须在拉起 Pod 之前就位
kubectl apply -f deploy/k8s/00-namespace.yaml

# 2) 建两个密钥。**密钥不在清单里**：放进去会被 apply 用占位值覆盖回去
#    api_key：上游的 WB2A_API_KEY 与面板的 WB2API_KEY 都读它，必建
kubectl -n workbuddy create secret generic workbuddy2api-secret \
  --from-literal=api_key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
#    面板初始密码：可选。不建则面板首启随机生成并打到日志里（见第 4 步）
kubectl -n workbuddy create secret generic workbuddy-manager-secret \
  --from-literal=admin-password="$(openssl rand -base64 18)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) 应用上游与面板
kubectl apply -f deploy/k8s/10-upstream.yaml deploy/k8s/20-manager.yaml
kubectl -n workbuddy rollout status deploy/workbuddy2api
kubectl -n workbuddy rollout status deploy/workbuddy-manager

# 4) 面板密码：建了 Secret 就是你给的那个；没建就从日志里捞
kubectl -n workbuddy logs deploy/workbuddy-manager | grep -A2 密码
```

> 顺序不是形式主义：`api_key` 缺失时上游与面板的 Pod 都会起不来，
> 面板的初始密码只在**首启**时被读取 —— 两个 Secret 都要排在拉 Pod 之前。

### 加账号

```bash
kubectl -n workbuddy exec -it deploy/workbuddy2api -- ./login.sh --realm=cn
#    国际版：--realm=global；不带参数且 stdin 是 tty 时会交互式问你要哪个域
```

**加完不用重启**：上游每 5 秒扫一次 `auths/`，新凭证自动进池。

### 改上游配置

配置来自 **ConfigMap `workbuddy2api-config`**（只读挂载），改它就是改这个对象：

```bash
# ① 在线编辑（存盘即更新对象）
kubectl -n workbuddy edit configmap workbuddy2api-config

# ② 或者改一份 YAML 再 apply（适合放进 Git 管理）
kubectl apply -f my-configmap.yaml

# 改完必须重启上游：上游只在启动时读一次配置
kubectl -n workbuddy rollout restart deploy/workbuddy2api
```

两点注意：

- 挂载走 `subPath`（单文件），**ConfigMap 更新不会自动进容器** —— 反正都要重启；
- **`api_key` 别在这里改**：它恒被 `WB2A_API_KEY` 覆盖（真源是 Secret），
  文件里留空即可；换密钥见下节。

### 验证

```bash
kubectl -n workbuddy port-forward svc/workbuddy2api 7863:7863 &    # 上游（可跳过）
curl -s http://127.0.0.1:7863/healthz

kubectl -n workbuddy port-forward svc/workbuddy-manager 7864:7864 &
# 浏览器打开 http://127.0.0.1:7864 ，用 admin + 上面的密码登录
```

`/healthz` 的 `healthy` / `total` 就是账号数。**账号池为空时它返回 503**，
这是上游的设计（判「能不能受理请求」），加进第一个账号就变 200 —— 不是装坏了。
面板的 `/api/healthz` 不受影响，一直是 200。

### 升级

```bash
# 上游：上游源码换新后本仓库会自动重建镜像，你只要让它重新拉
kubectl -n workbuddy rollout restart deploy/workbuddy2api
# 面板：官方镜像同理
kubectl -n workbuddy rollout restart deploy/workbuddy-manager
```

两个 Deployment 都是 `imagePullPolicy: Always`，重启即拉最新；卷不动，数据都在。
**分开部署的好处在这里体现**：升级面板不会动上游，反之亦然。

### 换掉 api_key

改 Secret，然后重启**两个** Deployment（上游用 `WB2A_API_KEY` 读它，面板用
`WB2API_KEY` 读它 —— 都来自同一个 Secret）：

```bash
kubectl -n workbuddy create secret generic workbuddy2api-secret \
  --from-literal=api_key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n workbuddy rollout restart deploy/workbuddy2api deploy/workbuddy-manager
```

## 换成 NFS / 云盘（动态供给）

默认 `hostPath` 最省事，但数据绑在节点上。多节点集群按需替换：

- **单节点 / 本地盘**：把 `hostPath` 换成 `local.path` + `nodeAffinity`
  （写法在 `10-upstream.yaml` 的注释里）。
- **NFS / 云盘 CSI**：**更省事的做法是把四个 PV 全删掉**，给四个 PVC 填上
  `storageClassName`（并删掉 `storageClassName: ""`），走动态供给。

## 有 RWX 存储时切回「共享卷」（找回面板的能力）

有 ReadWriteMany（NFS / CephFS / Longhorn 等）时可以让面板与上游共用一块卷。
但**账号和配置的「同步语义」完全不同**，所以推荐只共享 `auths/`：

### 方案 A（推荐）：只共享 `auths/` —— 加完立刻生效，不用重启

上游对 `auths/` 是**热加载**的（`internal/pool/watch.go` 每 5 秒重扫该目录），
面板扫码写进去的凭证会自动进池；而 `config.json` 仍然不给面板，于是
「配置同步」这个问题根本不存在。

1. 建一块 RWX 卷（静态 PV 或动态供给），只放 `auths/`。
2. **上游**：把 `auths` 那个卷换成它（`mountPath: /app/auths`），`config` 卷不动。
3. **面板**：把它挂到一个**独立路径**（例如 `/upstream-auths`），并加一个环境变量
   `WB_AUTH_DIR=/upstream-auths`；`/opt/workbuddy2api` 上的只读空卷**保持不变**。

> ⚠️ **别**把共享卷挂成 `/opt/workbuddy2api/auths`。容器运行时先挂只读的父目录，
> 再试图在它里面创建子挂载点，结果是**容器直接起不来**（实测报
> `mkdirat .../opt/workbuddy2api/auths: read-only file system`）。
> 两个挂载点必须互不嵌套 —— 用 `WB_AUTH_DIR` 把面板指过去即可（已实测：面板按该
> 变量走，写进去的文件确实落到共享卷上，而 `/opt/workbuddy2api` 下的写入仍被挡住）。

### 方案 B：把 `config.json` 换回可写卷 —— 能拿回设置页，但有个坑

方案 A 里 `config.json` 是只读的 ConfigMap，面板写不进去。想让「设置」页能保存，
就得把它从 ConfigMap 换回**一块可写卷**（一个 PV/PVC，像 `auths` 那样）：

- **上游**：`config` 卷从 `configMap:` 换回 `persistentVolumeClaim:`，挂载仍是
  `mountPath: /app/config.json` + `subPath: config.json`；因为文件必须存在，还得把
  之前删掉的 init 容器（从 ConfigMap 种一份初值）再放回来；
- **面板**：把这块卷挂到独立路径（例如 `/upstream-config`），并设
  `WB_UPSTREAM_CONFIG=/upstream-config/config.json`。

**代价：每次保存设置后必须自己重启上游**：

```bash
kubectl -n workbuddy rollout restart deploy/workbuddy2api
```

**上游只在启动时读一次配置** —— 源码 `cmd/server/main.go` 里只有一次 `Load`，
没有 fsnotify、没有 SIGHUP 重载、没有定时重读。Docker 部署里「保存即生效」是面板调
docker 把上游容器**重启**了，k8s 里没有这个能力。忘重启的症状是
**「设置页显示已保存、上游行为没变」**，很难查。

> `api_key` 由 Secret 经 `WB2A_API_KEY` 环境变量注入（**不落文件**），面板用的是
> `WB2API_KEY`（同一个 Secret）—— 两边始终一致，代价是**换密钥只能改 Secret**。
>
> 用 RWO 卷做共享时，两个 Pod 必须落在**同一节点**：给面板补一段 `podAffinity`
> （`topologyKey: kubernetes.io/hostname`，匹配 `app.kubernetes.io/name: workbuddy2api`）。
> 用 RWX 就不需要这段亲和。

## 常见坑

| 现象 | 原因 |
|---|---|
| PV 一直 `Pending` / PVC 绑不上 | `claimRef.namespace` 写错（换过命名空间？），或 PV 与 PVC 的 `storageClassName` 不一致 —— 静态供给时两边必须**同时**为空字符串或同时填同一个名字 |
| 上游或面板 Pod `CreateContainerConfigError` | 少了 Secret：`workbuddy2api-secret` 必建（两个组件都要它） |
| 面板报「读不到上游配置」/ 加账号写进了没人读的目录 | 预期行为，见「两个组件的边界」；要拿回这两项见下面「有 RWX 存储时切回共享卷」 |
| 共享卷模式下「设置页显示已保存，但上游行为没变」 | 忘了重启上游 —— 配置只在启动时读一次（见该小节的方案 B） |
| 账号数是 0，但 `auths/` 里明明有文件 | 卷属主不对（`fsGroup` 在 hostPath 这类卷上可能不生效）：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/auths` |
| 改了配置没生效 | 上游只在启动时读一次配置：改完 ConfigMap 要 `kubectl -n workbuddy rollout restart deploy/workbuddy2api` |
| 在 ConfigMap 里改 `api_key` 不生效 | 密钥由 Secret 经 `WB2A_API_KEY` 环境变量注入，**文件里的 api_key 恒被忽略**；换密钥只能改 Secret |
| 想扩上游副本 | **别扩**。账号池是单实例本地状态，多副本会重复跑定时任务并争抢 `state.json`；真要扩容先关掉 `config.json` 里的 `schedule.*` |
| 面板显示「上游不可用」 | `kubectl -n workbuddy exec deploy/workbuddy-manager -- curl -s http://workbuddy2api:7863/healthz`。注意 503 = 上游在跑但没有可用账号，不是连不上 |
