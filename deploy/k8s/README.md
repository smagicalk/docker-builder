# Kubernetes 部署清单

**只看这个目录 + 仓库根目录的 `docker-compose.yml`，就能把整套 WorkBuddy 跑起来。**

两个组件（面板 + 上游网关）是**两套独立的部署**：各带自己的 PersistentVolume、
各自的 Service、各自的 Deployment。面板**不挂上游的任何目录**，只通过 Service 走
HTTP 连过去 —— 所以两边互不等待，各自调度、各自升级重启。

| 组件 | 镜像 | 端口 | 存储 |
|---|---|---|---|
| 上游网关 | `ghcr.io/smagicalk/workbuddy2api:latest`（**本仓库自动构建**） | 7863 | 配置 / 凭证 / 池状态，3 块卷，上游独享 |
| 管理面板（入口） | `ghcr.io/ithtelab/workbuddy-manager:latest`（官方发布） | 7864 | 面板数据，1 块卷，面板独享 |

上游原仓库已不可访问，源码随 workbuddy-manager 的 Release 附件分发，
本仓库定时把它打包成镜像（见根目录 README 的「两种触发方式」）。

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `workbuddy`（PV 的 `claimRef` 依赖它） |
| `10-upstream.yaml` | 上游：3 PV + 3 PVC + ConfigMap + Deployment + Service |
| `20-manager.yaml` | 面板：1 PV + 1 PVC + Deployment + Service +（注释掉的）Ingress |

```bash
kubectl apply -f deploy/k8s/      # 按文件名顺序应用
```

## 存储对应表

四块 PV 都是 `hostPath` + `Retain`（删 PVC 不删数据），路径固定，一眼对得上：

| PV / PVC | 存储（宿主机路径） | 挂载点 | 里面是什么 | 丢了会怎样 |
|---|---|---|---|---|
| `workbuddy2api-config`（1Gi） | `/srv/workbuddy/upstream/config` | 上游 `/app/config.json`（subPath 单文件） | `config.json`：定时任务 / 限流 / 并发 / 提示词等全部配置 | 回落到模板（`api_key` 由 init 容器重新填入），改过的设置会丢 |
| `workbuddy2api-auths`（1Gi） | `/srv/workbuddy/upstream/auths` | 上游 `/app/auths` | 每个账号一份凭证 `workbuddy-<uid>.json` | **要重新扫码加号** —— 四块里最该备份的 |
| `workbuddy2api-pool`（1Gi） | `/srv/workbuddy/upstream/pool` | 上游 `/app/data` | `state.json`（积分/冷却/熔断）、`model.json`（成本账本） | 不致命，冷却与便宜号账本要重新学 |
| `workbuddy-manager-data`（5Gi） | `/srv/workbuddy/manager/data` | 面板 `/app/data` | `manager.db`（密钥/日志/用量/审计）、`users.json`（管理员 + 会话签名密钥） | 要重新初始化管理员、已发会话全部失效、统计与审计丢失 |

每块卷都是**独享**的：面板不挂上游那三块，上游也不挂面板那块。

## 两个组件的边界（为什么加账号要在上游做）

上游既没有「加账号」的 HTTP 接口，也没有热改配置的接口 —— 面板那两项功能天生
要靠**直接读写上游的 `auths/` 与 `config.json`**。所以拆开之后：

| 面板功能 | 拆开部署后 | 替代做法 |
|---|---|---|
| 扫码「添加账号」 | ✗ 按钮报错 | 在上游容器里登录（见下节） |
| 「设置」页保存 | ✗ 报错并锁定保存 | 改 `config.json` + 重启上游（见下节） |
| 上游重启 / 读上游日志 / 端口收敛 / 一键更新 | ✗ 降级提示（k8s 里没有 docker 守护进程） | `kubectl -n workbuddy logs\|rollout restart ...` |
| 仪表盘、账号列表、密钥分发、请求日志、用量统计、IP 管控、模型中心、聊天测试台 | ✓ 照常 | 只走 HTTP，不受影响 |

> 那两处报错是**预期的**：面板的设计就是「读失败明确报原因并锁定保存，
> 不用空配置覆盖真实文件」。**不要**用 emptyDir 之类把 `/opt/workbuddy2api` 造出来
> 「让它不报错」—— 那会让保存看起来成功了，而上游根本读不到，比报错更糟。
>
> 想把这四项能力全部找回来，见下面「有 RWX 存储时切回共享卷」。

## 部署

```bash
# 1) 先建命名空间 —— Secret 是命名空间级的，密钥必须在拉起 Pod 之前就位
kubectl apply -f deploy/k8s/00-namespace.yaml

# 2) 建两个密钥。**密钥不在清单里**：放进去会被 apply 用占位值覆盖回去
#    api_key：上游的 init 容器与面板的 WB2API_KEY 都读它，必建
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

`/app/config.json` 是 subPath 单文件挂载、可写，改动会直接落到配置卷上。
上游镜像里**没有 `vi`**（只有 `python3`），所以：

```bash
# ① 拽到本机改好再塞回去（顺手；容器里有 tar）
POD=$(kubectl -n workbuddy get pod -l app.kubernetes.io/name=workbuddy2api \
        -o jsonpath='{.items[0].metadata.name}')
kubectl -n workbuddy cp "$POD:/app/config.json" ./config.json
#    ……用你习惯的编辑器改 ./config.json……
kubectl -n workbuddy cp ./config.json "$POD:/app/config.json"
kubectl -n workbuddy rollout restart deploy/workbuddy2api

# ② 或者就地用 python 改一个字段
kubectl -n workbuddy exec -it deploy/workbuddy2api -- python3 -c \
  "import json;p='/app/config.json';c=json.load(open(p));c['schedule']['checkin_hours']=[8,20];json.dump(c,open(p,'w'),ensure_ascii=False,indent=2)"
kubectl -n workbuddy rollout restart deploy/workbuddy2api
```

上游**只在启动时读 `config.json`**，改完必须重启才生效。
`api_key` 别在这里改（每次启动都会被 init 容器用 Secret 的值覆盖，见下节）。

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

改 Secret，然后重启**两个** Deployment（上游的 init 容器会把新值写进
`config.json`，面板从同一个 Secret 读 `WB2API_KEY`）：

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

## 有 RWX 存储时切回「共享卷」（找回加账号 / 改设置）

有 ReadWriteMany（NFS / CephFS / Longhorn 等）时，可以让面板与上游共用一块卷，
面板的「添加账号」与「设置保存」就都能用了。改三处：

1. **建一块 RWX 卷**（静态 PV 或动态供给都行），例如 `workbuddy2api-shared`，
   里面放 `config.json` 与 `auths/` 两项。
2. **上游**（`10-upstream.yaml`）：把 `config` 与 `auths` 两个卷换成这一块，
   挂载写成 `mountPath: /app/auths` + `subPath: auths`、`mountPath: /app/config.json`
   + `subPath: config.json`；init 容器改挂到 `/cfg` 并加一句 `mkdir -p /cfg/auths`。
3. **面板**（`20-manager.yaml`）：加上这块卷并挂到 `/opt/workbuddy2api`
   （镜像里 `WB_AUTH_DIR` / `WB_UPSTREAM_CONFIG` 的默认值正好指向这里，不用设环境变量）。

> 用 RWO 卷做共享时，两个 Pod 必须落在**同一节点**：给面板补一段
> `podAffinity`（`topologyKey: kubernetes.io/hostname`，匹配
> `app.kubernetes.io/name: workbuddy2api`）。用 RWX 就不需要这段亲和。

## 常见坑

| 现象 | 原因 |
|---|---|
| PV 一直 `Pending` / PVC 绑不上 | `claimRef.namespace` 写错（换过命名空间？），或 PV 与 PVC 的 `storageClassName` 不一致 —— 静态供给时两边必须**同时**为空字符串或同时填同一个名字 |
| 上游或面板 Pod `CreateContainerConfigError` | 少了 Secret：`workbuddy2api-secret` 必建（两个组件都要它） |
| 面板报「读不到上游配置」/ 加账号报错 | 预期行为，见「两个组件的边界」；要用这两项就切回共享卷 |
| 账号数是 0，但 `auths/` 里明明有文件 | 卷属主不对（`fsGroup` 在 hostPath 这类卷上可能不生效）：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/auths` |
| 改了 `config.json` 没生效 | 上游要重启（见「改上游配置」） |
| 改完 `config.json` 又变回去了 | 那是 `api_key` 字段：它每次启动都由 init 容器从 Secret 重写，属正常 |
| 想扩上游副本 | **别扩**。账号池是单实例本地状态，多副本会重复跑定时任务并争抢 `state.json`；真要扩容先关掉 `config.json` 里的 `schedule.*` |
| 面板显示「上游不可用」 | `kubectl -n workbuddy exec deploy/workbuddy-manager -- curl -s http://workbuddy2api:7863/healthz`。注意 503 = 上游在跑但没有可用账号，不是连不上 |
