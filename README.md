# 上游镜像自动打包

把**没有官方镜像**的上游项目：定时检查更新 → 自动构建 → 推送 Docker 镜像。目前打了三个：

| 镜像 | 上游 | 流水线 | 平台 |
|---|---|---|---|
| `ghcr.io/<owner>/workbuddy2api` | [`ithtelab/workbuddy-manager`](https://github.com/ithtelab/workbuddy-manager) 的 Release 附件 [`upstream-src`](https://github.com/ithtelab/workbuddy-manager/releases/tag/upstream-src) | [`workbuddy2api.yml`](.github/workflows/workbuddy2api.yml) | amd64 + arm64 |
| `ghcr.io/<owner>/agents-anywhere` | [`anywhere-labs/Agents-Anywhere`](https://github.com/anywhere-labs/Agents-Anywhere) 的 GitHub Release | [`agents-anywhere.yml`](.github/workflows/agents-anywhere.yml) | amd64 |
| `ghcr.io/<owner>/paseo-relay` | [`getpaseo/paseo-relay`](https://github.com/getpaseo/paseo-relay) 的 **main 分支**（上游无 release / tag） | [`paseo-relay.yml`](.github/workflows/paseo-relay.yml) | amd64 + arm64 |

> **本仓库不含任何上游源码。** 源码只在构建时按附件 / release tag 现取，用完即弃。
> `deploy/` 下是「怎么把这些镜像跑起来」的说明（按项目分文件夹）。

下面**五节**（镜像在哪 / 两种触发方式 / 它怎么工作 / 首次使用 / 配置项）讲的都是
`workbuddy2api` 那条流水线；`agents-anywhere` 与 `paseo-relay` 的差异见后面各自的小节
（[agents-anywhere](#agents-anywhere-镜像) / [paseo-relay](#paseo-relay-镜像)）。

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

## agents-anywhere 镜像

上游 [`anywhere-labs/Agents-Anywhere`](https://github.com/anywhere-labs/Agents-Anywhere)：
**只发 release、不发镜像**（它的 compose 是 `build: context: ..`，Quickstart 也是让你本地 build），
所以本仓库在每个新 release 出来后，按那个 tag 构建一份。

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/<owner>/agents-anywhere` |
| 流水线 | [`agents-anywhere.yml`](.github/workflows/agents-anywhere.yml) |
| 触发 | 每 6 小时查一次**最新正式 release**（`/releases/latest`，不含 draft / prerelease）；也可手动 |
| 判断依据 | release tag 指向的**提交**（用 `sha-<前12位>` 探测），tag 被移动过（重新发布）也能认出来 |
| 标签 | `latest`（只给最新那份 release）、`vX.Y.Z`（对应 release）、`sha-<前12位>` |
| 平台 | **仅 linux/amd64** —— 它的构建含 Next.js，QEMU 下模拟 arm64 会慢到不可用 |
| 构建上下文 | release tag 的源码 tarball（整个仓库：`docker/Dockerfile` 要 `COPY web-next/` 与 `server/`） |

```bash
docker pull ghcr.io/<owner>/agents-anywhere:latest
```

**手动构建**：Actions → **agents-anywhere** → Run workflow —— 勾 `force` 忽略「已构建过」强制
重建；填 `tag`（例如 `v2.0.0`）重建某个历史 release（这种**不会**动 `latest`）。

> ⚠️ **许可**：上游仓库**没有声明 License**（GitHub API 返回 `null`）= 默认「保留所有权利」。
> 本流水线默认把镜像推到 GHCR（公开仓库默认就是公开包）。要收紧就去
> Packages → agents-anywhere → Package settings → Change visibility；或先给上游开个 issue 问一句。

## paseo-relay 镜像

上游 [`getpaseo/paseo-relay`](https://github.com/getpaseo/paseo-relay)：Paseo 的分布式中继
（Elixir/OTP 写的 WebSocket 中继，端口 4000）。**上游只发 main 分支，一个 release / tag 都没有**，
所以这条流水线直接跟 main 的 HEAD 走。

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/<owner>/paseo-relay` |
| 流水线 | [`paseo-relay.yml`](.github/workflows/paseo-relay.yml) |
| 触发 | 每 6 小时看一次 main 的 HEAD（提交没变就跳过，只花几秒）；也可手动 |
| 判断依据 | main HEAD 的**提交**（`sha-<前12位>` 内容寻址标签）—— 强推 / 回滚也认得出来 |
| 标签 | `latest` 与 `main`（都指 main 的最新构建）、`sha-<前12位>` |
| 平台 | amd64 + arm64（Elixir 是纯 BEAM 编译，QEMU 下可接受；两个基础镜像都是多架构的） |
| 构建上下文 | main 分支的源码 tarball（整仓库：根目录 `Dockerfile` 要 `COPY mix.exs / mix.lock / config / lib`） |
| 运行 | 监听 **4000**；`PASEO_RELAY_HOST` / `PASEO_RELAY_PORT` / `PASEO_RELAY_DRAIN` 可覆盖；`/metrics` 是 Prometheus 指标（细节见上游 `OPERATIONS.md`） |

```bash
docker pull ghcr.io/<owner>/paseo-relay:latest
```

**手动构建**：Actions → **paseo-relay** → Run workflow —— 勾 `force` 忽略「HEAD 没变」强制重建。

> 上游是 **Apache-2.0**（仓库里有 LICENSE），镜像标签里记了 `upstream.license=Apache-2.0`
> 与 `upstream.commit`，可以逐字对回是哪个提交打出来的。

---

## 部署与运行（都在 `deploy/` 下）

本仓库只管**打包上游镜像**；怎么把它跑起来，都在 `deploy/` 下按项目分文件夹 —— 两个项目各一套、
彼此无关（不同的库、不同的密钥，各用一个命名空间就好），每份都能独立看：

| 目录 | 内容 |
|---|---|
| [`deploy/workbuddy/`](deploy/workbuddy/README.md) | **项目总览**：上游 + 面板怎么配合，是下面三份的入口 |
| [`deploy/workbuddy/workbuddy2api/`](deploy/workbuddy/workbuddy2api/README.md) | 上游网关怎么跑：`docker-compose.yml`（只有 `image:`）+ 手册（准备 config / auths / data、属主 10001、起服务、扫码加号、验证、升级） |
| [`deploy/workbuddy/workbuddy-manager/`](deploy/workbuddy/workbuddy-manager/README.md) | 官方**面板**怎么配：环境变量、怎么连上游、`docker.sock` 挂不挂差在哪、让面板接管 Docker 部署的上游 |
| [`deploy/workbuddy/k8s/`](deploy/workbuddy/k8s/README.md) | Kubernetes：上游 + 面板**同一个 Pod** 的完整清单（4 PV/PVC、init 容器、2 Service、注释版 Ingress）与全部坑位 |
| [`deploy/agents-anywhere/`](deploy/agents-anywhere/README.md) | **Agents-Anywhere 总览**：上游服务端 + PostgreSQL 17 + Redis 8，`docker-compose.yml` 与 `k8s/` 两种跑法 |
| [`deploy/agents-anywhere/k8s/`](deploy/agents-anywhere/k8s/README.md) | Kubernetes：Postgres + Redis + Server 的完整清单（3 PV/PVC、迁移用的 init 容器、注释版 Ingress）与全部坑位 |

**WorkBuddy** 三者的关系一句话：上游镜像由**本仓库**构建 →
[`workbuddy2api/`](deploy/workbuddy/workbuddy2api/README.md) 讲怎么单独跑它 →
[`workbuddy-manager/`](deploy/workbuddy/workbuddy-manager/README.md) 讲面板怎么跟它配对 →
[`k8s/`](deploy/workbuddy/k8s/README.md) 把两者放进一个 Pod（共享 `config.json` 与 `auths/`，
面板的「扫码加号」「设置页保存」「成长中心任务」在那边才是完整可用的）。

**Agents-Anywhere** 更单纯：一个 `server` 加它自己的 Postgres 与 Redis，跟 WorkBuddy 毫无关系（不共享
任何库或密钥）。Docker 就一条 `docker compose up -d`；K8s 按
[`deploy/agents-anywhere/k8s/README.md`](deploy/agents-anywhere/k8s/README.md) 走 —— 里面写了
**空库首次的引导 token 怎么取**、升级时的停机窗口、以及扩 worker 的前提。

> 只想在单机上跑（不碰 Kubernetes）：WorkBuddy 看它的前两个文件夹就够 —— 上游一个 compose，
> 面板一个官方 compose（或 `docker run`），两者用同一个 Docker 网络互通；
> Agents-Anywhere 同理，`deploy/agents-anywhere/docker-compose.yml` 一条命令起全套。

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
