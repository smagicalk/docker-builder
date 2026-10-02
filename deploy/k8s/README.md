# Kubernetes 部署清单

**只看这个目录 + [`../workbuddy2api/`](../workbuddy2api/README.md) 与 [`../workbuddy-manager/`](../workbuddy-manager/README.md)，就能把整套 WorkBuddy 跑起来。**
（那两个文件夹分别是「上游怎么跑」与「面板怎么配」的手册；K8s 里两者被放进同一个 Pod。）

上游网关与面板放在**同一个 Deployment（同一个 Pod）**里，两个容器：

| 容器 | 镜像 | 端口 | 挂载的卷 |
|---|---|---|---|
| `workbuddy2api`（上游网关） | `ghcr.io/smagicalk/workbuddy2api:latest`（**本仓库自动构建**） | 7863 | 配置（只读）、凭证、池状态 |
| `workbuddy-manager`（面板，对外入口） | `ghcr.io/ithtelab/workbuddy-manager:latest`（官方发布） | 7864 | 面板数据、**配置（读写）**、**凭证** |

上游原仓库已不可访问，源码随 workbuddy-manager 的 Release 附件分发，
本仓库定时把它打包成镜像（见根目录 README 的「两种触发方式」）。

## 为什么合并成一个 Pod

上游既没有「加账号」的 HTTP 接口，也没有热改配置的接口 —— 面板那两项功能天生要靠
**直接读写上游的 `auths/` 与 `config.json`**。放进同一个 Pod，这两件事就退化成「挂同一块
卷」，于是：

- **不需要 `podAffinity`**：RWO 卷「只能挂在一个节点」的约束天然满足（同一个 Pod 不可能跨节点）；
- 面板直接用回环连上游（`WB2API_BASE=http://127.0.0.1:7863`），不必经过 Service；
- **「扫码添加账号」可用**：面板的 `WB_AUTH_DIR` 默认就是 `/opt/workbuddy2api/auths`，与上游的
  `/app/auths` 是同一块卷 —— 面板写进去，上游每 5 秒扫一次自动进池；
- **「设置」页保存可用**：两边读写的是**同一个 `config.json`**（同一个 inode，不是拷贝）。

代价（这些若对你更重要，就拆回两个 Deployment，见文末「拆成两套部署」）：

- **Pod Ready 是聚合的**：Service 的 endpoint 以 Pod 为单位 —— 上游容器崩了，整个 Pod 不算
  Ready，面板的 Service 也就不再有 endpoint。而「上游挂了还想打开面板看日志、改配置」恰恰
  是最需要面板的时候；
- **镜像拉取是单点**：两个容器都是 `:latest` + `Always`，任一方在 registry 抖动或被删 tag
  → Pod 起不来 → 两个一起不可用；
- **重启粒度粗**：只能整 Pod（改完配置要 `rollout restart`，面板跟着断几秒）。

## 关键设计一览

细节在各节，这是速查（总体取舍见上一节）：

| 点 | 做法 | 为什么 |
|---|---|---|
| 上游副本数 | **固定 `replicas: 1`** + `strategy: Recreate` | 账号池是单进程本地状态：多副本会各自跑一遍定时任务并争抢同一份 `state.json` |
| 配置生效 | 上游容器里跑一个 supervisor（清单里的 `command/args`），盯 `config.json` 的内容哈希 | 「保存即生效」（2~5 秒），不必重启 Pod、面板不中断 —— 见「配置为什么能『保存即生效』」 |
| 成长任务脚本 | init 容器从**上游镜像**复制 `/app/scripts/*.py` 到共享卷（emptyDir） | 面板「成长中心任务」可用，脚本版本与上游容器永远一致；复制失败只降级该功能，不挡 Pod 启动 |
| 卷属主 | `fsGroup: 10001` | 等价于 Docker 那步 `chown -R 10001:10001`，不用手工改 |
| hostPath 与多节点 | 四个 PV 都要加 `nodeAffinity` 钉到**同一台**节点，或改用 CSI 存储 | 不钉的话 Pod 落到别的节点会看到空目录：账号池变 0、配置回默认基线 —— 很像数据丢了 |
| 上游探针 | **TCP 探针**，不用 `/healthz` | `/healthz` 空池返回 503：当 liveness 会反复重启，当 readiness 会让加账号都做不了 |
| 面板探针 | `httpGet /api/healthz` | 该接口只返回 `{ok: true}`、不依赖上游，所以上游挂了面板仍 Ready |
| 容器端口名 | 上游 `api` / 面板 `web` | 同一个 Pod 里两个容器都有 http 端口时，Service 用命名端口会分不清该指向谁 |
| api_key | Secret 是唯一真源 | 两处都指向同一个 Secret，不会各说一套；`config.json` 里的 api_key 恒被忽略 |

## 文件与顺序

| 文件 | 内容 |
|---|---|
| `00-namespace.yaml` | 命名空间 `workbuddy`（PV 的 `claimRef` 依赖它） |
| `10-stack.yaml` | 4 PV + 4 PVC + Deployment（两个容器）+ 2 Service +（注释掉的）Ingress |

```bash
kubectl apply -f deploy/k8s/      # 按文件名顺序应用
```

## 存储对应表

四块 PV 都是 `hostPath` + `Retain`（删 PVC 不删数据），路径固定，一眼对得上：

| PV / PVC | 存储（宿主机路径） | 挂载点 | 里面是什么 | 丢了会怎样 |
|---|---|---|---|---|
| `workbuddy2api-config`（1Gi） | `/srv/workbuddy/upstream/config` | 上游 `/app/config.json`（只读）+ 面板 `/opt/workbuddy2api/config.json`（读写） | `config.json`（上游全部配置，**配置的唯一真源**） | 由 init 容器写一份默认基线（密钥不在里面） |
| `workbuddy2api-auths`（1Gi） | `/srv/workbuddy/upstream/auths` | 上游 `/app/auths` + 面板 `/opt/workbuddy2api/auths` | 每个账号一份凭证 `workbuddy-<uid>.json` | **要重新扫码加号** —— 最该备份的一个 |
| `workbuddy2api-pool`（1Gi） | `/srv/workbuddy/upstream/pool` | 上游 `/app/data`（面板**不挂**） | `state.json`（积分/冷却/熔断）、`model.json`（成本账本） | 不致命，冷却与便宜号账本要重新学 |
| `workbuddy-manager-data`（5Gi） | `/srv/workbuddy/manager/data` | 面板 `/app/data` | `manager.db`（密钥/日志/用量/审计）、`users.json`（管理员 + 会话签名密钥） | 要重新初始化管理员、已发会话全部失效、统计与审计丢失 |

**前两块是共享的**（面板与上游都挂）；`pool` 刻意不给面板：那是上游进程的活状态，
两个进程同时写只会互相覆盖（面板的写入是 tmp+rename，会被上游内存态直接盖掉）。

## 与官方 docker-compose 的对应关系

官方 [`docker-compose.yml`](https://github.com/ithtelab/workbuddy-manager/blob/main/docker-compose.yml)
给面板挂的是**上游整个仓库目录**：

```yaml
volumes:
  - ./data:/app/data                              # 面板数据
  - ../workbuddy2api:/opt/workbuddy2api           # 上游整个目录（读 + 写）
  - /var/run/docker.sock:/var/run/docker.sock     # 可选：挂上才能重载/更新上游
```

它自己在注释里就写明了替代做法：

> 若你**不想**让管理端碰上游仓库（例如上游由别人维护），改成只挂 `config.json` 与 `auths/`
> 两条子路径即可：此时「更新上游」会不可用，界面会如实提示。

本目录就是那个替代做法 —— K8s 里没有「上游仓库目录」这个概念（上游是另一个容器、另一个镜像），
所以只挂那两条子路径：

| 官方 compose | 本清单 |
|---|---|
| `../workbuddy2api:/opt/workbuddy2api`（整个目录） | `config.json`（subPath、**可写**）＋ `auths/`（**可写**）两条子路径 |
| `./data:/app/data` | PVC `workbuddy-manager-data` → `/app/data` |
| `docker.sock`（可选） | 没有也不可能有 → 重载 / 更新 / 读日志 / 端口收敛按官方说的「降级并如实提示」 |
| **不设** `WB_UPSTREAM_CONFIG` / `WB_AUTH_DIR` / `WB_UPSTREAM_DIR`（靠默认值指向 `/opt/workbuddy2api/*`） | **同样不设** —— 默认值正好命中挂载点，零覆盖 |

**为什么两条子路径就够**（不是推断：把面板源码的写入点全部过了一遍）：

| 面板写到哪 | 实际路径 | 本清单 |
|---|---|---|
| SQLite 库、`users.json`、`update-*`、`version-check.json`、`upstream-scripts/` | `/app/data`（`config.DATA_DIR`） | ✓ 已挂 |
| 上游配置（「设置」页保存） | `/opt/workbuddy2api/config.json` | ✓ 已挂（可写） |
| 账号凭证（扫码落盘） | `/opt/workbuddy2api/auths/`（`mkdir` + tmp+rename 原子写） | ✓ 已挂（可写） |
| 版本标记 `.version` | `/app/.version`（`config.ROOT`；写失败会自愈） | 容器层，无影响（官方也一样：`/app` 不是卷） |

**没有任何写入会落到 `/opt/workbuddy2api` 下的其它路径** —— 这是「两条子路径完备」的依据。
剩下的差异只有官方列出的那一项（「更新上游」不可用），外加 K8s 里本来就不成立的两项：
端口收敛（要读宿主机上的 compose 文件）与读上游日志（要读上游 `data/server.err.log`，
而 `data/` 刻意不共享，见上一节）。

还有一处**不是从上游目录来的**：面板的「成长中心任务」要跑上游自带的
`scripts/task_runner.py`（官方镜像把它 COPY 在 `/app/scripts/`）。K8s 里面板看不到另一个
容器的镜像内容，所以清单加了一个 init 容器把它复制到共享卷（emptyDir），面板按官方说的
「源码部署」路径 `<WB_UPSTREAM_DIR>/scripts/task_runner.py` 找到它 —— 脚本始终来自**同一个
上游镜像**，版本与上游容器一致（面板作者担心的「手工拷贝会漂移」在这里不成立）。

## 面板那几项「要靠上游文件」的功能

| 面板功能 | 状态 | 说明 |
|---|---|---|
| 扫码「添加账号」 | ✓ 可用 | 写进共享的 `auths/`，上游 5 秒内自动进池，**不用重启** |
| 「设置」页保存 | ✓ 保存成功，**2~5 秒自动生效** | 上游容器里的 supervisor 盯住文件内容、一变就优雅重启上游进程；界面那句「重载失败」是面板在试 docker，忽略即可 —— 见下节 |
| 「成长中心任务」（预览 / 一键执行） | ✓ 可用 | init 容器把上游镜像里的 `scripts/*.py` 复制到共享卷，面板按官方说的「源码部署」路径 `<WB_UPSTREAM_DIR>/scripts/task_runner.py` 找到它（实测接口 `available: true`）；脚本零第三方依赖，面板自己的 python3 直接跑 |
| 上游重启 / 读上游日志 / 端口收敛 / 一键更新 | ✗ 降级报错 | 面板镜像里**有** docker CLI（实测 `/usr/local/bin/docker` + compose v2.40.3），但 K8s 里没有 docker socket/守护进程 → 报 `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`（响亮、不静默）。用 `kubectl` 代替 |
| 仪表盘、账号列表、密钥分发、请求日志、用量统计、IP 管控、模型中心、聊天测试台 | ✓ 照常 | 只走 HTTP，不受影响 |

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

# 3) 应用整套
kubectl apply -f deploy/k8s/10-stack.yaml
kubectl -n workbuddy rollout status deploy/workbuddy

# 4) 面板密码：建了 Secret 就是你给的那个；没建就从日志里捞
kubectl -n workbuddy logs deploy/workbuddy -c workbuddy-manager | grep -A2 密码
```

> 顺序不是形式主义：`api_key` 缺失时两个容器都起不来（`CreateContainerConfigError`），
> 面板的初始密码只在**首启**时被读取 —— 两个 Secret 都要排在拉 Pod 之前。
> 两个容器在同一个 Pod 里，`logs` / `exec` 都要带 `-c` 指定容器。

### 加账号

首选面板的「扫码添加账号」（写共享 `auths/`，5 秒内进池）。要在容器里手工登录也可以：

```bash
kubectl -n workbuddy exec -it deploy/workbuddy -c workbuddy2api -- ./login.sh --realm=cn
#    国际版：--realm=global；不带参数且 stdin 是 tty 时会交互式问你要哪个域
```

> `login.sh` 末尾会试 `docker ps` / `docker restart`，在 K8s 里会误报
> 「容器 workbuddy2api 未运行，auth 文件已保存」—— **凭证其实已经存好了**，那两句是噪音。

### 改上游配置

**面板「设置」页保存**（推荐，界面会做字段白名单校验）—— **保存即生效，不用手动重启**：

上游容器里跑着一个极小的 supervisor（就是清单里 `workbuddy2api` 容器的 `command/args`），
它盯住 `config.json` 的**内容哈希**，一变就优雅重启上游进程（SIGTERM → 上游落盘 state 并等在途
请求结束）。本地实跑验证过：保存后 **2~5 秒**新配置生效，面板与整个 Pod 都不受影响。

> 界面仍会提示「上游重载失败：`Cannot connect to the Docker daemon…`」—— 那是面板按
> **Docker 部署**的思路去 `docker restart`，K8s 里没有 socket，所以这一步必然失败。
> **忽略即可**：配置已经由 supervisor 自动生效。想确认就看上游日志：
> `kubectl -n workbuddy logs deploy/workbuddy -c workbuddy2api | tail -20`
> （会看到 supervisor 的「内容已变，优雅重启上游进程」和上游新的 `listening on :7863`）。

也可以绕开面板。两条路都行，**改的是同一个文件，所以同样会自动生效**：

```bash
# ① 上节点直接改文件（hostPath 是节点上的真实路径）
sudo vi /srv/workbuddy/upstream/config/config.json

# ② 把本地准备好的一份文件灌进容器（适合把配置放进 Git 管理）
kubectl -n workbuddy exec -i deploy/workbuddy -c workbuddy-manager -- \
  sh -c 'cat > /opt/workbuddy2api/config.json' < my-config.json
```

几点注意：

- **`config.json` 的唯一真源就是卷上的这个文件** —— 清单里没有 ConfigMap 那一层「改了却对运行中的部署没用」的影子副本；写进去的内容都**永久保留**，重启不丢；
- 全新部署（文件还不存在）时由 init 容器写一份默认基线，之后它不再插手；
- **`api_key` 别在文件里改**：它恒被 `WB2A_API_KEY` 覆盖（真源是 Secret），留空即可；
- supervisor 只在文件**是合法 JSON** 时才动作，所以「面板先截断再写」的那一瞬间不会白白重启；配置语义非法导致上游起不来时，它每 3 秒重试一次（不刷屏），改好即自动恢复；
- 想关掉这个自动生效（例如你要手工调试）：把那个容器的 `command/args` 两行删掉，退回镜像默认的 ENTRYPOINT 即可。

### 验证

```bash
kubectl -n workbuddy port-forward svc/workbuddy-manager 7864:7864 &
# 浏览器打开 http://127.0.0.1:7864 ，用 admin + 上面的密码登录

# 可选：直接看上游（同一个 Pod，Service 只是给集群内其他客户端/调试用）
kubectl -n workbuddy port-forward svc/workbuddy2api 7863:7863 &
curl -s http://127.0.0.1:7863/healthz
```

`/healthz` 的 `healthy` / `total` 就是账号数。**账号池为空时它返回 503**，
这是上游的设计（判「能不能受理请求」），加进第一个账号就变 200 —— 不是装坏了。
面板的 `/api/healthz` 不受影响，一直是 200。

### 升级

```bash
# 上游源码换新后本仓库会自动重建镜像，你只要让它重新拉（面板也一起滚）
kubectl -n workbuddy rollout restart deploy/workbuddy
```

两个容器都是 `imagePullPolicy: Always`，重启即拉最新；卷不动，数据都在。
**代价**：同 Pod 里两个容器一起重启，面板也断几秒。想只升级其中一个，见文末「拆成两套部署」。

### 换掉 api_key

改 Secret，然后重启 Deployment（两个容器分别用 `WB2A_API_KEY` / `WB2API_KEY` 读它，
都来自同一个 Secret）：

```bash
kubectl -n workbuddy create secret generic workbuddy2api-secret \
  --from-literal=api_key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n workbuddy rollout restart deploy/workbuddy
```

## 多节点集群：hostPath 必须钉节点

`hostPath` 的数据只存在于**一个节点**上，而 Pod 可以调度到任何节点。落到没有数据的那台时，
你会看到：账号池变 0（`auths/` 是空的）、配置回到默认基线（init 又写了一份）—— 很像数据丢了，
其实数据好好地在另一台上。多节点集群里二选一：

**① 钉节点**（最小改动）：给四个 PV 都加上 `nodeAffinity`，值填 `kubectl get nodes` 里那个
`NAME`，**四个必须是同一台**（钉到不同节点会让 Pod 永远 `Pending`）：

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

然后保证 `/srv/workbuddy/upstream/{config,auths,pool}` 与 `/srv/workbuddy/manager/data`
都在那一台上。

**② 换 CSI 存储**（推荐做法）：按下一节把宿主机路径换成 NFS / 云盘 CSI，Pod 就能到处跑。

## 换成 NFS / 云盘（动态供给）

默认 `hostPath` 最省事，但数据绑在节点上。多节点集群按需替换：

- **单节点 / 本地盘**：把 `hostPath` 换成 `local.path` + `nodeAffinity`。
- **NFS / 云盘 CSI**：**更省事的做法是把四个 PV 全删掉**，给四个 PVC 填上
  `storageClassName`（并删掉 `storageClassName: ""`），走动态供给。
- 换成 RWX 存储后，理论上也能拆回两个 Deployment（各挂各的，不需要同节点）——
  但共享的 `config.json` 只保证「文件是最新」，不保证上游会重读 —— 本清单靠**上游容器里的
  supervisor**（`command/args`）自动重启上游进程；拆开部署时那段脚本要跟着上游容器走，
  否则又得手动重启。

## 配置为什么能「保存即生效」

上游只在**进程启动时**读一次 `config.json`（源码 `cmd/server/main.go` 里只有一次 `Load`，
没有 fsnotify、没有 SIGHUP）。面板保存后本来会按 Docker 部署的思路去 `docker restart`
上游容器 —— K8s 里没有 docker，于是「保存了却不生效」。

本清单的解法是给上游容器套一个 supervisor（就是 `workbuddy2api` 容器的那段 `command/args`，
**不碰上游代码**）：

- 把上游进程当子进程起来，每 2 秒算一次 `config.json` 的内容哈希（SHA-256）；
- 哈希变了 → 给子进程发 SIGTERM：上游会**落盘 state 并等在途请求结束**（其 main.go 的优雅
  停机），随后立刻重新拉起 —— 新配置就此生效；
- 文件**不是合法 JSON** 时不动手（避免「面板先截断再写」的瞬间白白重启一次）；
- 上游因配置语义非法起不来时，每 3 秒重试一次（不刷屏），改好即自动恢复；
- 容器停止时把 SIGTERM 转发给子进程 —— 否则 PID 1 是 shell，上游拿不到信号、来不及落盘。

**本地实跑验证过**（真镜像、用清单里那段脚本原文）：空转 12 秒 0 次重载；改端口后 1 次重载、
新端口立即可用且旧端口拒绝（证明确实重读了配置）；半截文件不重载且旧配置继续服务；坏配置下
每 3 秒重试、修好自动恢复；`docker stop` 时上游打了 `bye`（优雅退出）、退出码 0、耗时 0.6 秒。

> 另一条路是**让面板自己去重启**（`WB2API_MODE=native` + 两个启停脚本打 K8s API + 只允许
> patch 该 Deployment 的 RBAC）。本清单**没有**走这条：它要给面板容器放 ServiceAccount
> token（权限面更大），而且 `strategy: Recreate` 会让面板自己也被重启 —— 浏览器大概率看到
> 一次请求失败（配置其实已生效），体验反而不如 supervisor。

## 拆成两套部署（更看重面板独立可用时）

把 `10-stack.yaml` 里的 Deployment 拆成两个（上游 `workbuddy2api` + 面板
`workbuddy-manager`），各带自己的 Service，并把这几点对应改回去：

- 面板的 `WB2API_BASE` 改成 `http://workbuddy2api:7863`（跨 Pod 只能走 Service）；
- **加回 `podAffinity`**：`topologyKey: kubernetes.io/hostname` + 匹配
  `app.kubernetes.io/name: workbuddy2api` —— 共享的 RWO 卷要求两个 Pod 在同一节点；
- 面板不再挂共享 `auths` 的话，「扫码添加账号」会退化成**「看似成功、上游读不到」**：
  面板会自己 `mkdir` 出目录并写进容器自己的临时层（`server/services/tencent.py` 的
  `write_auth_file` 里是 `base.mkdir(parents=True, exist_ok=True)`，而镜像里
  `/opt/workbuddy2api` 本来就存在）。要么继续共享 `auths`（那就得留着 `podAffinity`），
  要么给 `/opt/workbuddy2api` 挂**只读空卷**把写入变成硬报错；
- 面板的 `WB_UPSTREAM_CONFIG` 要显式指到共享卷上的路径（例如
  `/upstream-config/config.json`），**并且同时把 `WB_UPSTREAM_DIR` 钉住**：它的默认值是
  `WB_UPSTREAM_CONFIG` 的父目录（`server/config.py`），不钉就会漂到共享卷上，而它被当成
  「上游仓库目录」用（更新器、`scripts/task_runner.py`、解析相对 `state_file`）。

换来的是：上游崩了面板照样对外服务（生产环境常碰到的需求）、两个镜像各自拉取互不影响、
可以只 `rollout restart deploy/workbuddy2api` 而面板不中断。

## 常见坑

| 现象 | 原因 |
|---|---|
| 账号池突然变 0、配置回到默认基线 | Pod 被调度到了**另一台节点** —— hostPath 的数据在那台上是空的（init 于是又写了一份新基线）。给四个 PV 加 `nodeAffinity` 钉住有数据的那台，或改用 CSI 存储；见「多节点集群」一节 |
| 面板报「未找到上游任务脚本（/app/data/upstream-scripts/task_runner.py）」 | init 容器 `copy-scripts` 没复制成功：`kubectl -n workbuddy logs deploy/workbuddy -c copy-scripts` 看日志（Pod 重启过就加 `--previous`）。只有「成长中心任务」受影响，其他功能照常 |
| 面板提示 `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` | **预期行为**：面板镜像自带 docker CLI，但 K8s 里没有 docker socket/守护进程 —— 「重载上游 / 读上游日志 / 一键更新 / 端口收敛」都会降级成这句。用 `kubectl -n workbuddy logs`、`rollout restart`、`port-forward` 代替 |
| 刷新令牌后出现「上游重载失败：…Cannot connect to the Docker daemon…请在宿主机重启上游容器」 | **不用处理**：这句针对的是面板顺手触发的「重启上游」——`server/services/reload.py` 开头写明账号类改动也会触发一次重启（好让旧上游不必等那 5 秒轮询），K8s 里没有 docker 所以必然失败。而上游对 `auths/` 是**热加载**（2026-09-18 起每 5 秒轮询目录指纹，`internal/pool/watch.go`），新令牌最多 5 秒进池；配置类改动则由上游容器里的 supervisor 自动生效 —— 这个提示一律可以忽略 |
| 面板提示「上游配置里声明的账号目录与本站读取的不一致，管理端实际以「账号目录」为准」 | **预期现象，不是配错**：面板把 config.json 里的 `auth_dir`（官方默认就是相对路径 `./auths`）与自己的 `WB_AUTH_DIR`（默认绝对路径 `/opt/workbuddy2api/auths`）做**字面**比较（`server/services/wb2api.py` 的 `load_upstream_config`），字面不同就带上 `upstream_auth_dir` 让界面提示。两边其实是**同一块卷**：上游的 CWD 是 `/app`，`./auths` 即 `/app/auths`；面板读的 `/opt/workbuddy2api/auths` 就是那块共享的 auths 卷。**官方 Docker 部署同样会显示这句**（它也不覆盖 `WB_AUTH_DIR`），而面板行为正确 —— 它就以自己的账号目录为准 |
| PV 一直 `Pending` / PVC 绑不上 | `claimRef.namespace` 写错（换过命名空间？），或 PV 与 PVC 的 `storageClassName` 不一致 —— 静态供给时两边必须**同时**为空字符串或同时填同一个名字 |
| Pod `CreateContainerConfigError` | 少了 `workbuddy2api-secret`（两个容器都要它） |
| 「设置页显示已保存，但上游行为没变」 | 正常情况**不会**再出现了：上游容器里的 supervisor 会自动重启上游进程。若真发生，先看它有没有报错：`kubectl -n workbuddy logs deploy/workbuddy -c workbuddy2api --tail=50`（找 `[supervisor]` 开头的行），并确认你没有把那个容器的 `command/args` 删掉 |
| 面板报 `Unexpected UTF-8 BOM`、设置页锁定 | 那个 `config.json` 带 BOM 了 —— Windows 记事本、PowerShell 5.1 的 `Set-Content -Encoding utf8` 默认都会写 BOM，而面板/上游都用严格 UTF-8 解析。重存为「UTF-8 **无 BOM**」（或用 `printf` / `python3` 写），面板自己保存出来的文件不带 BOM |
| `config.json` 不见了 / 配置被清空 | 配置卷空了：init 容器会**重新写入一份默认基线**（等于恢复出厂配置）。只有文件不存在时才会这样，正常改动造成的偏差不会被它覆盖 |
| 在 `config.json` 里改 `api_key` 不生效 | 密钥由 Secret 经 `WB2A_API_KEY` 注入，**文件里的 api_key 恒被忽略**；换密钥只能改 Secret |
| 面板「设置」保存报权限错误（Permission denied） | 宿主机上的 `config.json` 是别的用户（比如 root）建的，容器里的 10001 改不动：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/config` |
| 账号数是 0，但 `auths/` 里明明有文件 | 卷属主不对（`fsGroup` 在 hostPath 这类卷上可能不生效）：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/auths` |
| 面板保存时报「未找到上游配置文件 …」并锁定配置项 | `/opt/workbuddy2api/config.json` 没挂上（PVC 没绑，或 init 容器没写出基线）：`kubectl -n workbuddy exec deploy/workbuddy -c workbuddy-manager -- ls -l /opt/workbuddy2api`；init 的日志：`kubectl -n workbuddy logs deploy/workbuddy -c init-config`（已完成 Pod 用 `--previous`） |
| 想扩副本 | **别扩**。账号池是单实例本地状态，多副本会重复跑定时任务并争抢 `state.json`；真要扩容先关掉 `config.json` 里的 `schedule.*` |
| 面板显示「上游不可用」 | `kubectl -n workbuddy exec deploy/workbuddy -c workbuddy-manager -- curl -s http://127.0.0.1:7863/healthz`。注意 503 = 上游在跑但没有可用账号，不是连不上 |
| 改 Service 的 `targetPort` 时报找不到端口 | 两个容器都用**命名端口**，名字必须互不相同（上游 `api`、面板 `web`）：同名时 Service 分不清该指向哪个容器 |
