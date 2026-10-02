# workbuddy2api

给 [`ithtelab/workbuddy-manager`](https://github.com/ithtelab/workbuddy-manager) 的**上游
`workbuddy2api`** 自动打包 Docker 镜像。

官方只发布「面板」的镜像，**上游 workbuddy2api 没有官方镜像**——它的源码仓库已不可访问，
源码只能从 workbuddy-manager 的 Release 附件
[`upstream-src`](https://github.com/ithtelab/workbuddy-manager/releases/tag/upstream-src)
里拿（`workbuddy2api-src.tar.gz`）。结果是每台新机器部署时都得现 build 一遍上游。
本仓库把这件事自动化：**定时盯着那个附件，一变就自动构建并推送镜像。**

> **本仓库不含上游源码。** 源码只在构建时从 Release 附件现取，用完即弃。
> 这里只有一份 workflow、一份给消费端用的 compose 和这份说明。

---

## 镜像在哪

| 仓库 | 镜像名 | 说明 |
|---|---|---|
| GHCR | `ghcr.io/smagicalk/workbuddy2api` | 用内置 `GITHUB_TOKEN` 推送，无需额外配置 |
| Docker Hub | `docker.io/<DOCKERHUB_USERNAME>/workbuddy2api` | **可选**，配了下面两个 Secret 才推 |

标签：

| 标签 | 含义 |
|---|---|
| `latest` | 最新一份 |
| `packed-<YYYYMMDD>` | 按上游附件的打包日期 |
| `sha256-<前12位>` | 内容寻址，对应附件的 SHA-256；也是判断「有没有更新」的依据 |

平台 `linux/amd64` + `linux/arm64`，`docker pull` 会按机器架构自动选。

```bash
docker pull ghcr.io/smagicalk/workbuddy2api:latest
```

---

## 两种触发方式（自动 / 手动）

两条路并存，走的是同一条构建流程，产物完全一样：

| 方式 | 怎么触发 | 行为 |
|---|---|---|
| **自动** | 定时（`schedule`，每 6 小时） | 按附件摘要判断：没变就跳过，变了才构建推送 |
| **自动** | 推送本 workflow 文件（`push`，仅默认分支） | 同上。首次把仓库推上去会立刻出一份，不必等定时 |
| **手动** | Actions → **workbuddy2api** → **Run workflow** | 同上：按摘要判断，已是最新就跳过 |
| **手动** | 同上，勾上 **force** | **忽略「已是最新」判断**，无条件重新构建并推送 |

> **「Run workflow」按钮要在本文件推到默认分支之后才会出现。** 这个入口由 GitHub
> 按默认分支上的 workflow 列表生成 —— 文件还没推上去时 Actions 页是空的
> （定时任务同样不会跑）。推一次就有了。

装了 [`gh` CLI](https://cli.github.com/) 也可以在命令行发起（不必开浏览器）：

```bash
gh workflow run workbuddy2api.yml                  # 等价于点 Run workflow
gh workflow run workbuddy2api.yml -f force=true    # 强制重新构建
```

---
## 它怎么工作

```
每 6 小时（cron）
   │
   ├─ 查 Release API：ithtelab/workbuddy-manager → tag: upstream-src
   │     取附件 workbuddy2api-src.tar.gz 的 browser_download_url + digest(sha256)
   │
   ├─ 问镜像仓库：ghcr.io/<owner>/workbuddy2api:sha256-<前12位> 在不在？
   │     在  → 源码没变，跳过（不构建，只花几秒）
   │     不在 → 往下走
   │
   ├─ 下载附件 → 自算 sha256 与 API 给的核对 → 不一致就拒绝构建
   ├─ 解压（剥掉顶层目录到 src/，与 workbuddy-manager 的 install.sh 同一套处理）
   ├─ 用**上游自带的 Dockerfile** 构建 amd64 + arm64
   └─ 推 GHCR（配了 Secret 的话同时推 Docker Hub）
```

判断依据是**附件摘要**而不是「Release 有没有新提交」：维护者的更新方式是
`--clobber` 覆盖同一个附件，release 本身并不新发，所以只能靠内容摘要认变化。
这也让重复运行天然安全——同一个摘要第二次跑会直接跳过。

---

## 首次使用

1. 把这个仓库推上去（或在 GitHub 上 fork 后推一次）。
   `push` 触发只在**本 workflow 文件变化**时生效，所以推上来就会立刻构建一份，
   不用等定时。
2. 拉取：`docker pull ghcr.io/<你的用户名>/workbuddy2api:latest`
   > 公开仓库推出来的包**实测即可匿名拉取**，不用额外设置（本仓库已验证）。
   > 若你那边 `pull` 报 401，再去 **Packages → workbuddy2api → Package settings**
   > 把可见性改成 **Public** —— 包可见性只能在网页上改，workflow 里改不了。
3. （可选）要同时推一份到 Docker Hub，加两个 Secret 即可，见下面「配置项」。

镜像名里的用户名会自动取仓库所有者（含大写自动转小写，GHCR 不收大写名），
所以 fork 之后**不用改任何文件**。

---

## 配置项

全部在 **Settings → Secrets and variables → Actions**：

| 类型 | 名称 | 必需 | 说明 |
|---|---|---|---|
| Secret | `DOCKERHUB_USERNAME` | 否 | 配了才推 Docker Hub；两个都配才生效 |
| Secret | `DOCKERHUB_TOKEN` | 否 | Docker Hub [Access Token](https://hub.docker.com/settings/security)，权限 **Read & Write**（不是登录密码） |
| Variable | `IMAGE_NAME` | 否 | 改镜像名，默认 `workbuddy2api` |

两个 Docker Hub Secret 都没配时，相关步骤自动跳过，**不会把 workflow 标红**——
「没配」是正常状态。

**改轮询频率**：编辑 `.github/workflows/workbuddy2api.yml` 里的 cron

```yaml
  schedule:
    - cron: '17 */6 * * *'   # 每 6 小时；想每天一次就写 '17 3 * * *'
```

**手动触发 / 强制重建**：见上面「两种触发方式（自动 / 手动）」一节
（上游换了附件却没换摘要时，用 `force` 无条件重建）。

---

## 怎么跑起来（Docker）

上游自带的 `docker-compose.yml` 是**本地构建**的（`build: .`）。要用这份预构建镜像，
就把 compose 换成仓库根目录的 [`docker-compose.yml`](docker-compose.yml)（只有 `image:`、
没有 `build:`），或把那两个字段替换掉。

### 1. 准备三样东西

| 东西 | 作用 | 注意 |
|---|---|---|
| `config.json` | 上游配置 | **至少设 `api_key`** |
| `auths/` | 账号凭证 | **丢了要重新扫码** |
| `data/` | 账号池状态（`state.json` + 模型账本） | 丢了不致命，但冷却状态与便宜号账本要重新学 |

最小可用的 `config.json` —— **缺的字段全走上游默认值**（包括那套 9/21 点签到、
22 点保活的默认定时任务），所以写这四个键就能跑：

```json
{
  "listen": ":7863",
  "api_key": "把 `openssl rand -hex 32` 的结果贴这里",
  "auth_dir": "./auths",
  "state_file": "./data/state.json"
}
```

`api_key` **留空 = 完全不鉴权**，公网部署等于把账号池敞开。想要带全部字段的带注释基线，
从 Release 附件里取一份 `config.example.json`（注意示例里的 `test_key` 只是占位符）：

```bash
curl -fsSL https://github.com/ithtelab/workbuddy-manager/releases/download/upstream-src/workbuddy2api-src.tar.gz \
  | tar xz --strip-components=1 --wildcards '*/config.example.json'
```

### 2. 把两个目录的属主交给 10001

容器以 `app(uid 10001)` 运行。目录属主不对的话，账号数会一直是 0 而且**不报错** ——
这是最容易踩的一步：

```bash
chown -R 10001:10001 auths data
```

### 3. 起服务

```bash
docker compose up -d
docker compose logs -f      # 出现 "listening on :7863 (api_key=true)" 就是好了
```

> 日志里那个 `api_key=true` 就是**鉴权状态**：显示 `false` 说明你没设密钥、
> 接口对任何人开放。

不用 compose 的话，等价的一条命令：

```bash
docker run -d --name workbuddy2api --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -p 127.0.0.1:7863:7863 \
  -v "$PWD/auths:/app/auths" \
  -v "$PWD/data:/app/data" \
  -v "$PWD/config.json:/app/config.json:ro" \
  ghcr.io/smagicalk/workbuddy2api:latest
```

> 固定 `TZ=Asia/Shanghai` 是必要的：定时任务里「几点执行」按进程本地时区判定，
> 不设就按容器默认的 UTC 走，配置里的 `9 / 21` 点会变成北京时间 17 点 / 次日 5 点。

### 4. 加账号（扫码）

**要在容器内登录**：第 2 步把 `auths/` 交给 10001 之后，宿主机侧跑 `./login.sh` 会被
脚本自带的可写性预检直接拦下（不会白走一遍授权）。容器内的 `app` 自己落盘，属主天然正确：

```bash
docker compose exec -it workbuddy2api ./login.sh --realm=cn
# 国际版：--realm=global；不带参数且 stdin 是 tty 时会交互式问你要哪个域
```

按提示在浏览器里完成授权。加完**不用重启** —— 网关每 5 秒扫一次 `auths/`，新凭证自动进池
（日志会打 `新增账号自动加载，无需重启`）。

### 5. 验证

```bash
curl -s http://127.0.0.1:7863/healthz          # 无需鉴权
# {"healthy":1,"realm_servable":{"cn":true,"global":true},"service":"workbuddy2api","total":1}

K=<你的 api_key>
curl -s -H "Authorization: Bearer $K" http://127.0.0.1:7863/status
curl -s -H "Authorization: Bearer $K" http://127.0.0.1:7863/v1/models

curl -s http://127.0.0.1:7863/v1/chat/completions \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"glm-5.2","messages":[{"role":"user","content":"你好"}]}'
```

`/healthz` 里的 `healthy` / `total` 就是账号数。**账号池为空时它返回 503、`docker ps`
会显示 unhealthy** —— 这是上游的设计（用 `Pool.ServableNow()` 判「能不能受理请求」），
加进第一个账号就变 200，不是镜像坏了。

### 6. 更新镜像

```bash
docker compose pull && docker compose up -d
```

上游源码换新后本仓库会自动重建镜像（见上面「两种触发方式」），你这边 `pull` 一次即可；
`auths/` 与 `data/` 在卷里，升级不碰它们。

### 想让 workbuddy-manager 面板管它

面板的 `deploy/install.sh` 会对上游目录跑 `docker compose up -d --build`。把上游目录里的
compose 换成只有 `image:` 的版本即可（`--build` 对没有 `build:` 段的服务是空操作，
会直接用已拉取的镜像），`config.json` / `auths/` / `data/` 照旧保留。

---

## 在 Kubernetes 里跑（两套独立部署）

清单在 [`deploy/k8s/`](deploy/k8s/)。**上游与面板是两套独立的部署**：各带自己的
PersistentVolume、各自的 Service 与 Deployment，面板**不挂上游的任何目录**，
只通过 Service 走 HTTP 连过去（`WB2API_BASE=http://workbuddy2api:7863`）——
所以两边互不等待，各自调度、各自升级重启。

```bash
# 1) 命名空间 + 密钥。Secret 是命名空间级的，而且**刻意不放进清单** ——
#    放进清单会被 apply 用占位值把你的真密钥覆盖回去
kubectl apply -f deploy/k8s/00-namespace.yaml
kubectl -n workbuddy create secret generic workbuddy2api-secret \
  --from-literal=api_key="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) 上游 + 面板
kubectl apply -f deploy/k8s/10-upstream.yaml deploy/k8s/20-manager.yaml

# 3) 加账号、打开面板（首启随机密码在日志里）
kubectl -n workbuddy exec -it deploy/workbuddy2api -- ./login.sh --realm=cn
kubectl -n workbuddy logs deploy/workbuddy-manager | grep -A2 密码
kubectl -n workbuddy port-forward svc/workbuddy-manager 7864:7864
```

四块卷都是 `hostPath`（路径固定、`Retain` 不自动删）、**每个组件各自独享**：

| 卷 | 宿主机路径 | 挂给谁 | 里面是什么 |
|---|---|---|---|
| `workbuddy2api-config` 1Gi | `/srv/workbuddy/upstream/config` | 上游 `/app/config.json` | `config.json`（全部配置） |
| `workbuddy2api-auths` 1Gi | `/srv/workbuddy/upstream/auths` | 上游 `/app/auths` | 账号凭证（**最该备份的**） |
| `workbuddy2api-pool` 1Gi | `/srv/workbuddy/upstream/pool` | 上游 `/app/data` | `state.json`、成本账本 |
| `workbuddy-manager-data` 5Gi | `/srv/workbuddy/manager/data` | 面板 `/app/data` | SQLite 库、`users.json` |

**拆开部署的代价**（原因在上游的设计里：它既没有「加账号」的 HTTP 接口，也没有
热改配置的接口，那两项天生要靠直接读写上游的文件）：

| 面板功能 | 拆开后 | 替代做法 |
|---|---|---|
| 扫码「添加账号」 | ✗ **看似成功**：会写进面板容器自己的目录，上游读不到（显示「未加载」）、重启即丢 —— 清单里已用只读空卷把它变成硬报错 | 上游容器内执行 `./login.sh --realm=cn` |
| 「设置」页保存 | ✗ 读不到 `config.json` → 报错并锁定保存 | `kubectl cp` 改 `config.json` 再重启上游 |
| 重启上游 / 读上游日志 / 一键更新 / 端口收敛 | ✗ 降级提示（k8s 里没有 docker 守护进程） | `kubectl -n workbuddy logs`、`rollout restart` |
| 仪表盘、账号列表、密钥、日志、用量、IP 管控、模型中心、测试台 | ✓ 照常 | 只走 HTTP，不受影响 |

> 「添加账号」为什么会**看似成功**：面板落盘凭证时会自己 `mkdir` 出 `auths/`
> （`server/services/tencent.py` 的 `write_auth_file`），而镜像里 `/opt/workbuddy2api`
> 本来就存在 —— 于是它会写进面板容器自己那层临时文件系统。清单里给该路径挂了
> **只读空卷**，写入会立刻失败、当场暴露（**别**换成可写的 emptyDir）。
> 有 RWX 存储（NFS / CephFS / Longhorn）时可以**只共享 `auths/`** 找回「加账号」——
> 上游对它**热加载**（每 5 秒重扫目录），加完立刻生效、不用重启；「设置」则要连
> `config.json` 一起共享，**并自己重启上游**（上游只在启动时读一次配置）。
> 两个方案的挂法与坑（其中一个挂法会让容器起不来）都写在
> [`deploy/k8s/README.md`](deploy/k8s/README.md)。

几处刻意的设计（理由都写在清单注释里）：

| 点 | 做法 | 为什么 |
|---|---|---|
| 上游副本数 | **固定 `replicas: 1`** + `strategy: Recreate` | 账号池是单进程本地状态：多副本会各自跑一遍定时任务并争抢同一份 `state.json` |
| 面板与上游 | 不共享卷、无 `podAffinity` | 拆开部署后才能独立调度与升级：上游没起来，面板照样 Running 并显示「上游不可用」 |
| 卷属主 | `fsGroup: 10001` | 等价于 Docker 那步 `chown -R 10001:10001`，不用手工改 |
| 上游探针 | **TCP 探针**，不用 `/healthz` | `/healthz` 空池返回 503：当 liveness 会反复重启，当 readiness 会让加账号都做不了 |
| 面板探针 | `httpGet /api/healthz` | 该接口只返回 `{ok: true}`、不依赖上游，所以上游挂了面板仍 Ready |
| api_key | Secret 是唯一真源：上游 init 容器每次启动写进 `config.json`，面板读 `WB2API_KEY` | 上游的 `login.sh` 只认文件，面板要能鉴权；同一个 Secret 才不会各说一套 |

---

## 注意

- **这不是官方镜像。** 上游源码的许可为 MIT，版权归原作者（**Sliverkiss**）；
  镜像里的二进制由上游源码构建，请一并遵守其许可与使用边界（上游明确限
  「本人授权账号、本机 / 私有环境测试」）。镜像标签里写明了上游来源与附件摘要。
- **上游改了附件格式时工作流会明确失败**（找不到 `workbuddy2api-src.tar.gz`、
  摘要不一致、源码里没有 `Dockerfile` 都会 `::error::` 报出来并退出），
  不会悄悄产出一份错镜像。
- **GitHub 的 `schedule` 不保证准点**：负载高时会延迟，极端情况下会跳过某次；
  这是平台行为，不影响正确性——下一次跑到了还是会检出变化。
- 定时任务只在**默认分支**上生效（GitHub 的限制）。

---

## License

本仓库的 workflow 与文档：[MIT](LICENSE)。

镜像内含的上游 `workbuddy2api` 源码由原作者以 MIT 授权，版权归 **Sliverkiss**。
