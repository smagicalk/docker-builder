# WorkBuddy（上游网关 + 管理面板）

一套东西、两个组件，都在这个文件夹里：

| 子目录 | 是什么 | 镜像来源 |
|---|---|---|
| [`workbuddy2api/`](workbuddy2api/README.md) | **上游网关**（OpenAI 兼容），账号池本体 | **本仓库自动构建**：`ghcr.io/smagicalk/workbuddy2api:latest`（见[仓库根 README](../../README.md)） |
| [`workbuddy-manager/`](workbuddy-manager/README.md) | **管理面板**，整套的对外入口（下游客户端连它的 `/v1`） | 官方发布：`ghcr.io/ithtelab/workbuddy-manager:latest` |
| [`k8s/`](k8s/README.md) | **Kubernetes 清单**：把上面两个放进**同一个 Pod** 的一套完整部署 | — |

## 两种跑法

**① 单机 / Docker（两个组件各自一个容器）**

- 上游：照 [`workbuddy2api/README.md`](workbuddy2api/README.md)，用同目录那份只有 `image:` 的 compose
- 面板：用官方 compose（或 `docker run`），按 [`workbuddy-manager/README.md`](workbuddy-manager/README.md) 配置
- 两者放进同一个 Docker 网络用服务名互连（面板的 `WB2API_BASE=http://workbuddy2api:7863`）

**② Kubernetes（一个 Deployment、两个容器）**

照 [`k8s/README.md`](k8s/README.md)。为什么合成一个 Pod：上游既没有「加账号」的 HTTP 接口，
也没有热改配置的接口 —— 面板那两项功能天生要靠**直接读写上游的 `auths/` 与 `config.json`**，
同 Pod 就能挂同一块卷，于是「扫码加号」「设置页保存（改完自动生效）」「成长中心任务」全都可用。

## 组件的配合关系（一句话版）

```
下游客户端 ──> 面板 :7864（密钥 / 配额 / IP 管控 / 用量日志都在面板侧）
                └──> 上游 :7863（账号池、定时任务；只在启动时读一次 config.json）
                       ↑
        面板与上游共享 config.json + auths/（K8s：同一个 Pod 挂同一块卷）
```

- **鉴权**：面板用 `WB2API_KEY` 调上游，上游用 `WB2A_API_KEY` 校验 —— 两边指向同一把钥匙。
- **账号**：凭证放在 `auths/`，上游每 5 秒扫一次自动进池，所以**加号不用重启**。
- **配置**：`config.json` 只在进程启动时读一次；Docker 部署下靠 `docker restart`、
  K8s 清单里靠容器内的 supervisor 自动重启上游进程（详见 k8s 那份文档）。
