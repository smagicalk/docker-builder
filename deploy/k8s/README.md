# Kubernetes 部署清单

**只看这个目录 + 仓库根目录的 `docker-compose.yml`，就能把整套 WorkBuddy 跑起来。**

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

## 面板那几项「要靠上游文件」的功能

| 面板功能 | 状态 | 说明 |
|---|---|---|
| 扫码「添加账号」 | ✓ 可用 | 写进共享的 `auths/`，上游 5 秒内自动进池，**不用重启** |
| 「设置」页保存 | ✓ 保存成功，⚠️ **生效要重启** | 上游只在启动时读一次配置，没有热重载 —— 见下节 |
| 上游重启 / 读上游日志 / 端口收敛 / 一键更新 | ✗ 降级报错 | K8s 里没有 docker 守护进程，面板也看不到上游工作目录；用 `kubectl` 代替 |
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

**面板「设置」页保存**（推荐，界面会做字段白名单校验）：

```bash
# 面板保存后，让上游重新读一次配置 —— 必须重启，上游没有热重载
kubectl -n workbuddy rollout restart deploy/workbuddy
```

面板在保存后还会自己尝试「重启上游容器」，这一步在 K8s 里**必然失败**（没有 docker），
界面会提示重载失败 —— **那不是保存失败**，按上面那行命令重启即可。

也可以绕开面板。两条路，随你：

```bash
# ① 上节点直接改文件（hostPath 是节点上的真实路径）
sudo vi /srv/workbuddy/upstream/config/config.json
kubectl -n workbuddy rollout restart deploy/workbuddy

# ② 把本地准备好的一份文件灌进容器（适合把配置放进 Git 管理）
kubectl -n workbuddy exec -i deploy/workbuddy -c workbuddy-manager -- \
  sh -c 'cat > /opt/workbuddy2api/config.json' < my-config.json
kubectl -n workbuddy rollout restart deploy/workbuddy
```

> 两条路改的都是**同一个文件**（面板读写的就是它）：改动永久生效，只是上游要重启才会读到。

四点注意：

- **`config.json` 的唯一真源就是卷上的这个文件** —— 清单里没有 ConfigMap 那一层「改了却对运行中的部署没用」的影子副本；面板保存、你改宿主机文件、或者把一份新文件灌进容器，写进去的内容都**永久保留**；
- 全新部署（文件还不存在）时由 init 容器写一份默认基线，之后它不再插手；
- **`api_key` 别在文件里改**：它恒被 `WB2A_API_KEY` 覆盖（真源是 Secret），留空即可；
- 别忘了重启：症状是**「设置页显示已保存、上游行为没变」**，很难查。

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
  但共享的 `config.json` 仍然只保证「文件是最新」，不保证上游会重读，重启那一步省不掉。

## 可选：让「保存」自动触发重启（未实测）

配置只在启动时被读一次，所以「保存即生效」在 K8s 里需要有人去重启上游。
面板本身支持**原生模式**：`WB2API_MODE=native` 时会执行
`WB2API_STOP_SCRIPT` 与 `WB2API_START_SCRIPT` 两个脚本（源码 `server/config.py`、
`server/services/wb2api.py`）。把 START 脚本写成「打 K8s API 给本 Deployment 打一个
`restartedAt` 注解」，就能做到面板保存后自动滚动重启：

- 脚本用 ConfigMap 挂进来，注意 `defaultMode: 0755`（**必须可执行**），且**必须立即返回**
  （面板对脚本有超时，挂住会杀进程并报错）；
- 需要 ServiceAccount + Role/RoleBinding，**只允许 patch 这一个 Deployment**；
- 重启的是整个 Pod（面板也会重启几秒），并且会出现「保存成功 → 页面短暂 502」的观感。

这段本仓库**没有实测**，只是把可行的钩子写清楚；不配就是现在这样：保存成功 + 手动重启。

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
| 账号池突然变 0、配置回到默认基线 | Pod 被调度到了**另一台节点** —— hostPath 的数据在那台上是空的（init 于是又写了一份新基线）。给四个 PV 加 `nodeAffinity` 钉住有数据的那台，或改用 CSI 存储；见「多节点集群」一节 |
|---|---|
| PV 一直 `Pending` / PVC 绑不上 | `claimRef.namespace` 写错（换过命名空间？），或 PV 与 PVC 的 `storageClassName` 不一致 —— 静态供给时两边必须**同时**为空字符串或同时填同一个名字 |
| Pod `CreateContainerConfigError` | 少了 `workbuddy2api-secret`（两个容器都要它） |
| 「设置页显示已保存，但上游行为没变」 | 忘了重启：`kubectl -n workbuddy rollout restart deploy/workbuddy`（配置只在启动时读一次） |
| `config.json` 不见了 / 配置被清空 | 配置卷空了：init 容器会**重新写入一份默认基线**（等于恢复出厂配置）。只有文件不存在时才会这样，正常改动造成的偏差不会被它覆盖 |
| 在 `config.json` 里改 `api_key` 不生效 | 密钥由 Secret 经 `WB2A_API_KEY` 注入，**文件里的 api_key 恒被忽略**；换密钥只能改 Secret |
| 面板「设置」保存报权限错误（Permission denied） | 宿主机上的 `config.json` 是别的用户（比如 root）建的，容器里的 10001 改不动：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/config` |
| 账号数是 0，但 `auths/` 里明明有文件 | 卷属主不对（`fsGroup` 在 hostPath 这类卷上可能不生效）：上节点 `chown -R 10001:10001 /srv/workbuddy/upstream/auths` |
| 面板保存时报「未找到上游配置文件 …」并锁定配置项 | `/opt/workbuddy2api/config.json` 没挂上（PVC 没绑，或 init 容器没写出基线）：`kubectl -n workbuddy exec deploy/workbuddy -c workbuddy-manager -- ls -l /opt/workbuddy2api`；init 的日志：`kubectl -n workbuddy logs deploy/workbuddy -c init-config`（已完成 Pod 用 `--previous`） |
| 想扩副本 | **别扩**。账号池是单实例本地状态，多副本会重复跑定时任务并争抢 `state.json`；真要扩容先关掉 `config.json` 里的 `schedule.*` |
| 面板显示「上游不可用」 | `kubectl -n workbuddy exec deploy/workbuddy -c workbuddy-manager -- curl -s http://127.0.0.1:7863/healthz`。注意 503 = 上游在跑但没有可用账号，不是连不上 |
| 改 Service 的 `targetPort` 时报找不到端口 | 两个容器都用**命名端口**，名字必须互不相同（上游 `api`、面板 `web`）：同名时 Service 分不清该指向哪个容器 |
