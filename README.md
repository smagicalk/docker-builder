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

## 拉下来怎么跑

上游自带的 `docker-compose.yml` 是**本地构建**的（`build: .`）。要用预构建镜像，
把 compose 换成仓库根目录的 [`docker-compose.yml`](docker-compose.yml)（只有 `image:`，
没有 `build:`），或直接把那两个字段替换掉。

```bash
# 目录里要有：config.json（含 api_key）、auths/、data/
docker compose up -d
curl -s http://127.0.0.1:7863/healthz
```
（`healthy` / `total` 就是账号数；**账号池为空时 `/healthz` 返回 503、`docker ps` 会显示 unhealthy
—— 这是上游的设计，加进第一个账号后就变 200，不是镜像坏了。**）

> 想让 workbuddy-manager 面板也用这份镜像：面板的 `deploy/install.sh` 会对上游目录跑
> `docker compose up -d --build`。把上游目录里的 compose 改成只有 `image:` 的版本即可
> （`--build` 对没有 `build:` 段的服务是空操作，会直接用已有/已拉取的镜像）。
> 上游的 `config.json`、`auths/`、`data/` 照旧保留，不受影响。

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
