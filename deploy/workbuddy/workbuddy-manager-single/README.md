# WorkBuddy 单容器试验部署

本目录是现有 [`../k8s/`](../k8s/) 双容器方案的**可选替代方案**：将 WorkBuddy Manager 与 workbuddy2api 放进同一个容器进程空间，以 `WB2API_MODE=native` 和 Linux 启停脚本控制上游进程。

> 旧的 `deploy/workbuddy/k8s/` 与 `deploy/workbuddy/workbuddy-manager/` 文件保留，不会由本方案删除或覆盖。单容器镜像由 `.github/workflows/workbuddy-manager-combined.yml` 独立构建，镜像名为 `ghcr.io/<owner>/workbuddy-manager-combined`。
>
> 这是试验部署：复合镜像仍需在目标集群验证。**切换时先停旧 Deployment**，否则两个管理端/上游实例会同时写共享 PVC。

## 镜像构建

Workflow 每 6 小时查询一次 `ithtelab/workbuddy-manager` 最新正式 Release，也可在 Actions 手动运行。默认 tag 使用上游 Release tag，同时推送 `latest`。构建前校验 Release tar.gz 的 SHA-256，并确认包内有 `server/`、`upstream/` 和 Go module。

GHCR 示例：

```text
ghcr.io/smagicalk/workbuddy-manager-combined:latest
ghcr.io/smagicalk/workbuddy-manager-combined:v1.0.80
```

## 持久化路径与旧方案对照

单容器方案继续使用旧 K8s Deployment 的四个 PVC 与相同宿主机目录；**不需要搬数据或新建 PVC**。但挂载位置需按下表配置：

| PVC | 节点目录（沿用旧值） | 旧双容器挂载 | 单容器挂载 | 内容 |
|---|---|---|---|---|
| `workbuddy2api-config` | `/srv/workbuddy/upstream/config` | 上游 `/app/config.json`；管理端 `/opt/workbuddy2api/config.json` | `/opt/workbuddy2api/config.json` | 上游唯一配置真源；保留当前文件，不要让 init 覆盖 |
| `workbuddy2api-auths` | `/srv/workbuddy/upstream/auths` | 上游 `/app/auths`；管理端 `/opt/workbuddy2api/auths` | `/opt/workbuddy2api/auths` | 账号凭证；丢失需要重新扫码 |
| `workbuddy2api-pool` | `/srv/workbuddy/upstream/pool` | 上游 `/app/data` | `/opt/workbuddy2api/data` | `state.json`、冷却状态、模型账本及上游日志 |
| `workbuddy-manager-data` | `/srv/workbuddy/manager/data` | 管理端 `/app/data` | `/app/data` | `manager.db`、`users.json`、审计、密钥、统计 |

**不能把 pool PVC 挂到 `/app/data`**：那是面板自己的数据目录。两个 PVC 必须分别挂在上述路径。

成长任务脚本已随复合镜像放在 `/opt/workbuddy2api/scripts/`，Dockerfile 与上游源码来自同一个 Release，不需要旧方案的 `upstream-scripts` `emptyDir` 或脚本复制 init container。

## 迁移步骤

1. **先做数据备份**，尤其 `auths`、`config.json` 和 manager 数据目录。
2. 确认现有 Secret 仍在 `workbuddy` 命名空间：`workbuddy2api-secret`（`api_key` 必需）和可选的 `workbuddy-manager-secret`（`admin-password`）。不要在新 YAML 写入真实密钥。
3. 等复合镜像构建成功，并确认目标 registry tag 可拉取。
4. 停止旧 Deployment，避免新旧容器并发写 PVC：

   ```bash
   kubectl -n workbuddy scale deploy/workbuddy --replicas=0
   kubectl -n workbuddy rollout status deploy/workbuddy
   ```

5. 将本目录 `10-stack.yaml` 中镜像改为你要部署的固定 tag（推荐 Release tag，不要长期依赖 `latest`），再应用：

   ```bash
   kubectl apply -f deploy/workbuddy/workbuddy-manager-single/10-stack.yaml
   kubectl -n workbuddy rollout status deploy/workbuddy-single
   ```

6. 检查 Pod、两项健康接口、面板账号数量和设置页保存：

   ```bash
   kubectl -n workbuddy get pods -o wide
   kubectl -n workbuddy logs deploy/workbuddy-single -c workbuddy-single
   kubectl -n workbuddy port-forward svc/workbuddy-manager 7864:7864
   # 新终端中检查管理端
   curl -i http://127.0.0.1:7864/api/healthz
   # 集群内或 port-forward 时检查上游；空账号池的 /healthz 返回 503 是上游既有语义
   kubectl -n workbuddy port-forward svc/workbuddy2api 7863:7863
   curl -i http://127.0.0.1:7863/healthz
   ```

7. 确认一切正常后，保留旧 `workbuddy` Deployment manifest 供回滚；不要删除旧 K8s 文件或 PVC。

### 回滚

```bash
kubectl -n workbuddy scale deploy/workbuddy-single --replicas=0
kubectl -n workbuddy rollout status deploy/workbuddy-single
# 恢复旧 Service selector 和旧 Deployment 规格（保留 PVC 不动）
kubectl apply -f deploy/workbuddy/k8s/10-stack.yaml
kubectl -n workbuddy scale deploy/workbuddy --replicas=1
kubectl -n workbuddy rollout status deploy/workbuddy
```

确保任何时候只有一个 Deployment 使用这些共享 PVC。回滚不删除 PVC 或数据。

## 与旧方案的差异

- 单容器入口脚本运行 manager 和上游 Go 进程；Kubernetes 停 Pod 时先调用 Linux stop script，再退出 manager。
- 上游重载走 `WB2API_MODE=native` 的 stop/start 脚本，不调用 Docker daemon。
- manager 和上游日志都落在容器 stdout/stderr 或各自数据目录；上游 stderr 文件位于 `/opt/workbuddy2api/data/server.err.log`。
- K8s 探针检查 manager `/api/healthz`，不依赖上游账号池；上游 `/healthz` 在空池时可返回 503，不能作为 Pod 存活判断。
- 仍为单副本。上游定时任务与池状态不适合多副本共享运行。
- 单容器不提供 Docker API；面板的 Docker 专属“一键更新上游/读 Docker 容器日志”等操作仍不适用。上游二进制更新需构建并部署新的复合镜像。
