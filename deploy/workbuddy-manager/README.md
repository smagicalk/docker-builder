# 管理面板 workbuddy-manager —— 怎么配

面板用**官方镜像** `ghcr.io/ithtelab/workbuddy-manager:latest`（多架构）。
本仓库**不打包面板** —— 只负责上游 `workbuddy2api` 的镜像，见
[`../workbuddy2api/README.md`](../workbuddy2api/README.md)。

它在整套里是**对外入口**：下游客户端连它的 `/v1`（密钥、配额、IP 白名单、请求日志、用量统计
都在面板侧），它再通过 HTTP 调上游。仓库根 README 只讲打包镜像，运行相关都在 `deploy/` 下。

| 项 | 值 |
|---|---|
| 监听端口 | `7864`（`WB_MANAGER_PORT` 可改） |
| 健康检查 | `GET /api/healthz` → `{"ok": true}`（**不依赖上游**，所以上游挂了面板仍 Ready） |
| 首启管理员密码 | 用 `WB_ADMIN_PASSWORD` 指定；**不设**则随机生成并打进容器日志（日志里搜「密码」），且只在首次启动时生效 |

> ⚠️ 面板持有**全部账号凭据**：公网使用必须放在反向代理之后并配 TLS，别直接把 7864 暴露出去。
> 官方 compose 默认就是 `127.0.0.1:7864:7864`。

## 怎么连上游（`WB2API_BASE`）

| 场景 | 取值 |
|---|---|
| 同一个 compose / Docker 网络（推荐） | `http://workbuddy2api:7863`（服务名） |
| 上游跑在宿主机上 | `http://host.docker.internal:7863` |
| Kubernetes 里同上一个 Pod（本仓库那种） | `http://127.0.0.1:7863`（回环；跨 Pod 才需要 Service 名） |

`WB2API_KEY` 必须与上游的 `api_key` **一致**：上游侧用 `WB2A_API_KEY` 注入同一个值
（上游的配置文件里 `api_key` 恒为空、被环境变量覆盖）。

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `TZ` | — | 面板展示的定时任务时间；**必须与上游同一个值**（如 `Asia/Shanghai`），否则界面时间和实际执行时间差 8 小时 |
| `WB_ADMIN_PASSWORD` | 空 | 首启管理员密码，只在第一次启动时读取 |
| `WB2API_BASE` | `http://127.0.0.1:7863` | 上游地址 |
| `WB2API_KEY` | 空 | 与上游之间的鉴权密钥（同上） |
| `WB2API_CONTAINER` | `workbuddy2api` | 上游**容器名**：`docker restart` / `docker logs` / 提取任务脚本都按它找容器（K8s 里没有 docker，这几项会降级） |
| `WB2API_MODE` | `docker` | `docker`=用 docker 操作上游容器；`native`=执行 `WB2API_START_SCRIPT` / `WB2API_STOP_SCRIPT` 两个脚本 |
| `WB_AUTH_DIR` | `/opt/workbuddy2api/auths` | 面板读写账号凭证的目录（**必须与上游看到的 auths 是同一份**） |
| `WB_UPSTREAM_CONFIG` | `/opt/workbuddy2api/config.json` | 上游配置文件路径（「设置」页保存的就是它） |
| `WB_UPSTREAM_DIR` | = `WB_UPSTREAM_CONFIG` 的父目录 | 上游目录。被当成「上游仓库目录」用（更新器、`scripts/task_runner.py`、解析配置里相对的 `state_file`）——**单独改 `WB_UPSTREAM_CONFIG` 时一定要把它一起钉住**，否则它会跟着漂 |
| `WB_DATA_DIR` | `/app/data` | 面板自己的 SQLite / users.json / 更新状态 |
| `WB_TRUST_PROXY` | `1` | 反代后面取真实 IP（读 `X-Real-IP`） |
| `WB_TRUSTED_PROXY_HOPS` | `1` | 前面叠了几层代理 |
| `WB_ENABLE_DOCS` | `0` | 是否暴露 `/docs` 与 `/openapi.json`（生产别开） |

只列了常用的；完整清单（含子路径部署要用的 `WB_BASE_PATH` 等）见上游仓库的
`server/config.py` 与官方 `docker-compose.yml`。

## `docker.sock`：挂不挂，差在哪

官方 compose 默认挂 `/var/run/docker.sock`。挂上之后面板能做四件事：

- 保存设置后**自动重载**上游容器（`docker restart`）
- 读上游日志（`docker logs`）
- 「一键更新上游」
- 端口收敛（读上游的 compose 文件）

**不挂**也能跑：那几项会降级成「请到宿主机执行 `docker compose ...`」，界面如实提示，
不会静默失败。挂上去等于把宿主机 root 权限交给这个容器 —— 官方 compose 的注释里有详细权衡
（宿主部署本来就以 root 运行，权限等价）。

## 面板需要上游的哪些目录

官方 compose 挂的是上游**整个仓库目录**（`../workbuddy2api:/opt/workbuddy2api`），一次覆盖三件事：
读/写 `config.json`、读/写 `auths/`（**不能只读**：扫码落盘、令牌刷新都要写回）、读上游
compose 做端口收敛 / `git pull` 更新上游。

**不想让面板碰上游仓库**（比如上游由别人维护）时，按官方注释只挂 `config.json` 与 `auths/`
两条子路径即可 —— 代价是「更新上游」不可用，界面会如实提示。本仓库的 K8s 清单正是这种做法：
见 [`../k8s/README.md`](../k8s/README.md)。

## 让面板接管 Docker 部署的上游

面板的 `deploy/install.sh` 会对上游目录跑 `docker compose up -d --build`。把上游目录里的 compose
换成只有 `image:` 的那份（[`../workbuddy2api/docker-compose.yml`](../workbuddy2api/docker-compose.yml)）即可：
`--build` 对没有 `build:` 段的服务是空操作，会直接用已拉取的镜像；`config.json` / `auths/` /
`data/` 照旧保留。

## 在 Kubernetes 里

上游与面板放进**同一个 Pod**（共享 `config.json` 与 `auths/`，面板那两项「天生要靠直接读写上游
文件」的功能才完整可用），清单与完整说明：[`../k8s/README.md`](../k8s/README.md)。

与 Docker 部署的差异，一句话版：**没有 docker.sock**（上面那四项降级）；配置改动由上游容器里的
supervisor 自动重启上游进程生效（2~5 秒）；「成长中心任务」的脚本由 init 容器从上游镜像复制
进来，可用。
