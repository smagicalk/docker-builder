# Kubernetes 部署清单

**只看这个目录 + 仓库根目录的 `docker-compose.yml`，就能把整套 WorkBuddy 跑起来。**
这套清单包含两个组件 —— 面板（入口，对外）与上游网关（账号池，只对内）——
以及它们各自需要的 PersistentVolume / PersistentVolumeClaim。

其中**上游镜像由本仓库自动构建**（`ghcr.io/smagicalk/workbuddy2api:latest`）：
上游原仓库已不可访问，源码随 workbuddy-manager 的 Release 附件分发，
本仓库定时把它打包成镜像（见根目录 README 的「两种触发方式」）。
面板用官方发布的那份（`ghcr.io/ithtelab/workbuddy-manager:latest`）。

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `workbuddy`（PV 的 `claimRef` 和组件互连都依赖它） |
| `10-upstream.yaml` | 上游：2 PV + 2 PVC + Secret + ConfigMap + Deployment + Service |
| `20-manager.yaml` | 面板：1 PV + 1 PVC + Secret + Deployment + Service +（注释掉的）Ingress |

```bash
kubectl apply -f deploy/k8s/      # 按文件名顺序应用，顺序就是上面的顺序
```

顺序有意义：面板要用 Service 名连上游，还要挂上游 init 容器准备好的共享卷，所以**上游必须先起**。

## 存储对应表

三块 PV 都是 `hostPath` + `Retain`（删 PVC 不删数据），路径固定，一眼能对上：

| PV / PVC | 存储（宿主机路径） | 挂载点 | 里面是什么 | 丢了会怎样 |
|---|---|---|---|---|
| `workbuddy2api-shared`（1Gi） | `/srv/workbuddy/shared` | 上游 `/app/auths` + `/app/config.json`；面板 `/opt/workbuddy2api` | `auths/` 账号凭证、`config.json` 配置 | **要重新扫码加号**；配置回落到模板 |
| `workbuddy2api-pool`（1Gi） | `/srv/workbuddy/upstream-pool` | 上游 `/app/data` | `state.json`（积分/冷却/熔断）、`model.json`（成本账本） | 不致命，但冷却状态与便宜号账本要重新学 |
| `workbuddy-manager-data`（5Gi） | `/srv/workbuddy/manager-data` | 面板 `/app/data` | `manager.db`（密钥/日志/用量/审计）、`users.json`（管理员 + 会话签名密钥） | 要重新初始化管理员、已发会话全部失效、统计与审计丢失 |

两点说明：

- **`workbuddy2api-shared` 是两个组件共享的**（名字里的 `shared` 就是这个意思）。
  所以它是 `ReadWriteOnce`：同一块卷能被**同一节点**上的多个 Pod 挂载，但不能跨节点 ——
  面板因此用 `podAffinity` 钉在上游所在的节点上。
- **`config.json` 刻意放在可写卷里**，不是 ConfigMap/Secret：面板的「设置」页要就地改它。
  密钥的真源是 Secret，由上游的 init 容器在每次启动时同步进这个文件
  （面板与上游的 `login.sh` 都从这个文件读密钥）。

## 部署

```bash
# 1) 先建命名空间 —— Secret 是命名空间级的，密钥必须在拉起 Pod 之前就位
kubectl apply -f deploy/k8s/00-namespace.yaml

# 2) 建两个密钥。**密钥不在清单里**：放进去会被 apply 用占位值覆盖回去
#    api_key：上游的 init 容器要读它，必建
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

> 这个顺序不是形式主义：`api_key` 缺失时上游 Pod 直接起不来（init 容器读不到它），
> 面板的初始密码只在**首启**时被读取 —— 所以两个 Secret 都要排在拉 Pod 之前。

### 加账号

两条路都行：

```bash
# A. 上游容器内扫码（推荐，最直接）
kubectl -n workbuddy exec -it deploy/workbuddy2api -- ./login.sh --realm=cn
#    国际版：--realm=global
# B. 面板界面里点「添加账号」——面板也是写 auths/，同样能落盘
```

**加完不用重启**：上游每 5 秒扫一次 `auths/`，新凭证自动进池。

### 验证

```bash
kubectl -n workbuddy port-forward svc/workbuddy2api 7863:7863 &   # 上游（可跳过，看面板即可）
curl -s http://127.0.0.1:7863/healthz

kubectl -n workbuddy port-forward svc/workbuddy-manager 7864:7864 &
# 浏览器打开 http://127.0.0.1:7864 ，用 admin + 上面的密码登录
```

`/healthz` 的 `healthy` / `total` 就是账号数。**账号池为空时它返回 503**，
这是上游的设计（判「能不能受理请求」），加进第一个账号就变 200 —— 不是装坏了。
面板的 `/api/healthz` 不受影响，一直是 200。

### 改设置

面板「设置」页保存后会写 `config.json`。**k8s 里没有自动重载**（那是 docker 的功能），
保存完自己滚一次上游：

```bash
kubectl -n workbuddy rollout restart deploy/workbuddy2api
```

### 升级镜像

```bash
# 上游：上游源码换新后本仓库会自动重建镜像，你只要让它重新拉
kubectl -n workbuddy rollout restart deploy/workbuddy2api
# 面板：官方镜像同理
kubectl -n workbuddy rollout restart deploy/workbuddy-manager
```

两个 Deployment 都是 `imagePullPolicy: Always`，重启即拉最新。
卷不动，账号与数据都在。

### 换掉 api_key

改 Secret，然后重启**两个** Deployment（上游的 init 容器会把新值同步进 `config.json`）：

```bash
kubectl -n workbuddy create secret generic workbuddy2api-secret \
  --from-literal=api_key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n workbuddy rollout restart deploy/workbuddy2api deploy/workbuddy-manager
```

## 与 Docker 部署的能力差异

k8s 里容器运行时是 containerd，**没有 docker 守护进程**，所以面板里这几项会
**降级为「请到宿主机操作」并在界面如实提示**（不会静默失败）：

| 面板功能 | k8s 里的替代做法 |
|---|---|
| 保存设置后自动重载上游 | `kubectl -n workbuddy rollout restart deploy/workbuddy2api` |
| 读上游日志 | `kubectl -n workbuddy logs deploy/workbuddy2api` |
| 一键更新上游 / 管理端 | 拉新镜像后 `rollout restart`（更新管理端源码那套不适用） |
| 上游端口收敛 | 不适用：网络由 Service 管 |

**账号管理、密钥分发、日志、用量统计、IP 管控、模型中心、测试台全部照常可用** ——
它们只依赖 HTTP 与那两个卷。

## 换成 NFS / 云盘

默认的 `hostPath` 最省事，但数据绑在节点上。多节点集群按需替换：

- **单节点 / 本地盘**：把 `hostPath` 换成 `local.path` + `nodeAffinity`（写法在
  `10-upstream.yaml` 的注释里）。
- **NFS / CephFS / 云盘 CSI**：把 PV 里的 `hostPath` 段换成 `nfs:` / `csi:`；
  若集群有默认 StorageClass，**更省事的做法是删掉这些 PV**，改成动态供给 ——
  给 PVC 填上 `storageClassName`（并删掉 `storageClassName: ""`）。
- 共享卷换成 ReadWriteMany 之后，`20-manager.yaml` 里的 `podAffinity` 可以删掉
  （那时两个 Pod 可以落在不同节点）。

## 常见坑

| 现象 | 原因 |
|---|---|
| PV 一直 `Pending` / PVC 绑不上 | `claimRef.namespace` 写错（换过命名空间？），或 PV 与 PVC 的 `storageClassName` 不一致 —— 静态供给时两边必须**同时**为空字符串或同时填同一个名字 |
| 面板 Pod `Pending` | `podAffinity` 找不到上游 Pod：上游没起来 / 标签被改过。先确认 `kubectl -n workbuddy get pods` 里上游是 Running |
| 账号数是 0，但 `auths/` 里明明有文件 | 卷属主不对（`fsGroup` 在 hostPath 这类卷上可能不生效）：上节点 `chown -R 10001:10001 /srv/workbuddy/shared/auths` |
| 改了 `config.json` 没生效 | 上游要重启（见「改设置」） |
| 想扩副本 | **别扩**。账号池是单实例本地状态，多副本会重复跑定时任务并争抢 `state.json`；真要扩容先关掉 `config.json` 里的 `schedule.*` |
| 面板显示「上游不可用」 | `kubectl -n workbuddy exec deploy/workbuddy-manager -- curl -s http://workbuddy2api:7863/healthz`。注意 503 = 上游在跑但没有可用账号，不是连不上 |
