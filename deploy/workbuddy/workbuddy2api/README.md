# 上游 workbuddy2api（OpenAI 兼容网关）—— 怎么跑

镜像由本仓库自动构建：`ghcr.io/smagicalk/workbuddy2api:latest`（多架构 amd64 + arm64）。
标签含义、构建机制、怎么手动触发，见[仓库根 README](../../../README.md)。

| 文件 | 用途 |
|---|---|
| `docker-compose.yml` | 用**预构建镜像**跑上游：与上游自带那份的差别只有一处 —— 把 `build: .` 换成 `image:`，不再本地编译 |
| 本文件 | 跑起来的手册（Docker 为主） |

> - **Kubernetes**：上游与面板放进**同一个 Pod**，整套清单与说明在 [`../k8s/`](../k8s/README.md) ——
>   那边已经包含上游容器，不用在这里重复配。
> - **面板**：官方 `workbuddy-manager` 怎么跟它配对，见 [`../workbuddy-manager/README.md`](../workbuddy-manager/README.md)。

## 1. 准备三样东西

| 东西 | 作用 | 注意 |
|---|---|---|
| `config.json` | 上游配置 | **至少设 `api_key`** |
| `auths/` | 账号凭证 | **丢了要重新扫码** |
| `data/` | 账号池状态（`state.json` + 模型账本） | 丢了不致命，但冷却状态与便宜号账本要重新学 |

最小可用的 `config.json` —— **缺的字段全走上游默认值**（包括那套 9/21 点签到、22 点保活的
默认定时任务），所以写这四个键就能跑：

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

## 2. 把两个目录的属主交给 10001

容器以 `app(uid 10001)` 运行。目录属主不对的话，账号数会一直是 0 而且**不报错** ——
这是最容易踩的一步：

```bash
chown -R 10001:10001 auths data
```

## 3. 起服务

```bash
docker compose up -d
docker compose logs -f      # 出现 "listening on :7863 (api_key=true)" 就是好了
```

> 日志里那个 `api_key=true` 就是**鉴权状态**：显示 `false` 说明你没设密钥、接口对任何人开放。

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

## 4. 加账号（扫码）

**要在容器内登录**：第 2 步把 `auths/` 交给 10001 之后，宿主机侧跑 `./login.sh` 会被
脚本自带的可写性预检直接拦下（不会白走一遍授权）。容器内的 `app` 自己落盘，属主天然正确：

```bash
docker compose exec -it workbuddy2api ./login.sh --realm=cn
# 国际版：--realm=global；不带参数且 stdin 是 tty 时会交互式问你要哪个域
```

按提示在浏览器里完成授权。加完**不用重启** —— 网关每 5 秒扫一次 `auths/`，新凭证自动进池
（日志会打 `新增账号自动加载，无需重启`）。

## 5. 验证

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
（所以 K8s 里那个容器的探针用的是 **TCP**，不是 `/healthz`。见 [`../k8s/README.md`](../k8s/README.md)。）

## 6. 更新镜像

```bash
docker compose pull && docker compose up -d
```

上游源码换新后本仓库会自动重建镜像（见根 README 的「两种触发方式」），你这边 `pull` 一次即可；
`auths/` 与 `data/` 在卷里，升级不碰它们。

## 想让 workbuddy-manager 面板接管它

见 [`../workbuddy-manager/README.md`](../workbuddy-manager/README.md) 的「让面板接管 Docker 部署的上游」：
把上游目录里的 compose 换成这个目录里那份（只有 `image:`）即可。

## 注意

这不是官方镜像：上游源码版权归原作者 **Sliverkiss**（MIT），上游明确限「本人授权账号、
本机 / 私有环境测试」。镜像里的二进制由上游源码构建，请一并遵守其许可与使用边界。
