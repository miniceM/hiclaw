# 开发指南

为 HiClaw 贡献代码、本地构建镜像和运行测试的指南。

## 前置条件

- Docker（用于构建和测试）
- Git
- `mc`（MinIO Client，用于运行集成测试）
- `jq`（用于测试脚本中的 JSON 处理）

## 项目结构

参见 [../AGENTS.md](../AGENTS.md) 获取完整的代码库导航指南。

## 本地构建镜像

所有构建都通过根目录的 `Makefile` 进行：

```bash
# 构建 Manager 和 Worker 镜像（原生架构，用于本地开发/测试）
make build

# 仅构建 Manager
make build-manager

# 仅构建 Worker
make build-worker

# 使用指定版本标签构建
make build VERSION=0.1.0

# 为指定平台构建
make build DOCKER_PLATFORM=linux/amd64
```

运行 `make help` 查看所有可用目标。

### 推送镜像（默认多架构）

`make push` 始终构建多架构 manifest（amd64 + arm64），避免意外用单架构镜像覆盖多架构镜像。使用 `docker buildx`：

```bash
# 构建 amd64 + arm64 并推送到镜像仓库
make push VERSION=0.1.0 REGISTRY=ghcr.io REPO=higress-group/hiclaw

# 仅推送 Manager（多架构）
make push-manager VERSION=latest

# 自定义平台（默认：linux/amd64,linux/arm64）
make push MULTIARCH_PLATFORMS=linux/amd64,linux/arm64,linux/arm/v7
```

> **注意**：`make push` 始终直接推送到镜像仓库（buildx 多平台构建的要求——多架构镜像无法存储在本地 Docker 镜像仓库中）。推送前需先执行 `docker login`。
>
> 本地开发和测试请使用 `make build`，它会在本地创建原生架构镜像。如果确实需要推送单架构镜像（不推荐），使用 `make push-native`。

### 镜像源

所有基础镜像均来自公共镜像仓库：
- **openclaw-base**: `hiclaw/openclaw-base:latest`（GitHub Packages）
- **Tuwunel**: `ghcr.io/girlbossceo/conduwuit:latest`（GitHub Container Registry）
- **MinIO**: `quay.io/minio/minio:latest`（Quay.io）
- **Element Web**: `vectorim/element-web:latest`（Docker Hub）

**注意**：GHCR 镜像可能需要登录或配置镜像加速器。如遇拉取问题，可通过环境变量自定义镜像源：

```bash
make build-manager TUWUNEL_IMAGE=<alternative-image>
```

如遇网络问题，可配置 Docker 镜像加速器或使用代理。

## 安装 / 卸载 / Replay

### 快速安装（最简）

只需 `HICLAW_LLM_API_KEY`，其余均使用合理默认值：

```bash
# 一条命令完成镜像构建 + Manager 安装
HICLAW_LLM_API_KEY="sk-xxx" make install
```

此命令将：
1. 构建 Manager 和 Worker 镜像（`make build`）
2. 运行安装脚本（`install/hiclaw-install.sh manager`）
3. 挂载容器运行时 socket 以支持直接创建 Worker
4. 将配置保存到 `./hiclaw-manager.env`

### 自定义安装

通过环境变量覆盖任意配置：

```bash
HICLAW_LLM_API_KEY="sk-xxx" \
HICLAW_LLM_PROVIDER="openai" \
HICLAW_DEFAULT_MODEL="gpt-4o" \
HICLAW_ADMIN_USER="myadmin" \
HICLAW_ADMIN_PASSWORD="mypassword" \
make install
```

### 卸载

```bash
make uninstall   # 停止 Manager，删除所有 Worker 容器、数据卷和 env 文件
```

### Replay（向 Manager 发送任务）

安装完成后，通过 Matrix 协议向 Manager 发送任务：

```bash
# CLI 模式：通过参数传递任务
make replay TASK="为前端开发创建一个名为 alice 的 Worker"

# 交互模式：提示输入
make replay

# 管道模式：从 stdin 读取
echo "创建 Worker bob" | ./scripts/replay-task.sh
```

replay 脚本会：
- 从 `./hiclaw-manager.env` 读取凭据
- 以管理员身份登录 Matrix
- 查找（或自动创建）与 Manager 的私信房间
- 发送任务消息
- 等待并打印 Manager 的回复（可通过 `REPLAY_WAIT=0` 跳过等待）
- 将对话日志保存到 `logs/replay/replay-{timestamp}.log`（通过 `make replay-log` 查看）

### 对已安装的 Manager 运行测试

执行 `make install` 后，可以直接对运行中的 Manager 运行测试套件，无需重新构建或创建新容器：

```bash
make test-installed

# 或指定测试过滤器
make test-installed TEST_FILTER="01 02"
```

此命令从 `./hiclaw-manager.env` 读取凭据，跳过容器生命周期管理（启动/停止）。

## 运行测试

### 完整集成测试套件

```bash
# 构建镜像 + 运行全部 10 个测试用例
export HICLAW_LLM_API_KEY="your-api-key"
make test
```

### 运行指定测试

```bash
# 仅运行测试 01、02、03
make test TEST_FILTER="01 02 03"
```

### 跳过镜像构建

```bash
# 使用已有镜像（加快迭代速度）
make test SKIP_BUILD=1
```

### 快速冒烟测试

```bash
# 仅运行 test-01（快速健康检查）
make test-quick
```

### GitHub 测试（08-10）

测试 08-10 需要 GitHub 个人访问令牌：

```bash
export HICLAW_GITHUB_TOKEN="ghp_..."
make test TEST_FILTER="08 09 10"
```

## 修改代码

### 修改 Agent 行为

Agent 行为由 Markdown 文件定义，而非代码：
- **Manager SOUL**：`manager/agent/SOUL.md`
- **Manager 心跳**：`manager/agent/HEARTBEAT.md`
- **技能**：`manager/agent/skills/*/SKILL.md`

### 修改启动序列

每个组件在 `manager/scripts/init/` 中都有独立的启动脚本：
- 修改对应的 `start-*.sh` 脚本
- 重新构建 Manager 镜像
- 运行测试验证

### 添加新的 MCP Server

1. 在 `manager/agent/skills/worker-management/scripts/create-worker.sh` 的 `generate_mcporter_config()` 函数中添加服务器配置
2. 在 Manager 容器环境变量中添加相应的凭据（如 `HICLAW_GITHUB_TOKEN`）
3. 创建 Worker 技能 SKILL.md，记录可用工具
4. 在 `manager/agent/worker-skills/` 中更新新技能
5. 在 `tests/` 中添加测试覆盖

## CI/CD

### GitHub Actions 工作流

| 工作流 | 触发条件 | 用途 | 架构 |
|--------|----------|------|------|
| `build.yml` | PR 到 main | 仅构建（不推送，快速反馈） | amd64 |
| `build.yml` | 推送到 main | 多架构构建 + 推送 | amd64 + arm64 |
| `integration-test.yml` | main 构建成功后 | 运行完整测试套件 | amd64（runner 原生） |
| `release.yml` | 版本标签 `v*` | 多架构构建 + 推送发布镜像 | amd64 + arm64 |

所有 CI 多架构构建使用 `docker/setup-qemu-action` 进行跨平台模拟，并通过 `make push` 调用 `docker buildx`。

### 所需 Secrets

| Secret | 用途 |
|--------|------|
| `HICLAW_LLM_API_KEY` | Agent 行为测试的 LLM 访问 |
| `HICLAW_GITHUB_TOKEN` | 测试 08-10 的 GitHub 操作 |

### 本地 CI 模拟

```bash
# 与 CI 相同的流程，但在本地运行（单架构）
export HICLAW_LLM_API_KEY="your-key"
make test

# 像 CI 在 main 分支上那样进行多架构构建
docker login ghcr.io
make push VERSION=latest REGISTRY=ghcr.io REPO=higress-group/hiclaw
```

## 网络代理配置（中国大陆）

构建镜像需要访问 GitHub（用于 `git clone`）和 npm 镜像源。在中国大陆环境中通常需要代理。

### 宿主机代理

在运行命令前在 shell 中启用代理：

```bash
# 启用代理（根据你的代理配置调整端口）
export http_proxy="http://127.0.0.1:1087"
export https_proxy="http://127.0.0.1:1087"
export ALL_PROXY="socks5://127.0.0.1:1086"

# 重要：将 localhost 排除在代理之外，否则测试健康检查会失败
export no_proxy="localhost,127.0.0.1,::1,local,169.254/16"
```

### Docker 构建代理

Docker 构建在隔离环境中运行，**不会**继承宿主机的代理设置。通过 `DOCKER_BUILD_ARGS` 传递代理：

```bash
make build-manager DOCKER_BUILD_ARGS="--build-arg http_proxy=http://host.docker.internal:1087 --build-arg https_proxy=http://host.docker.internal:1087"
```

> **注意**：`host.docker.internal` 在 Docker 容器内解析为宿主机。如果代理监听在宿主机的 `127.0.0.1:1087`，在构建参数中使用 `host.docker.internal:1087`。

### 运行测试时的代理配置

运行测试时 `no_proxy` 至关重要——没有它，测试对 `127.0.0.1` 的健康检查会经过代理并返回 503：

```bash
export no_proxy="localhost,127.0.0.1,::1,local,169.254/16"
HICLAW_LLM_API_KEY="your-key" make test SKIP_BUILD=1
```

## 容器运行时 Socket（直接创建 Worker）

当 Manager 容器启动时挂载了宿主机的容器运行时 socket，它可以直接创建 Worker 容器——本地部署无需人工干预。

### 工作原理

Manager 在启动时检测 socket 并设置 `HICLAW_CONTAINER_RUNTIME=socket`。`container-api.sh` 脚本通过 Docker 兼容的 REST API 提供创建/启动/停止 Worker 容器的函数（同时支持 Docker 和 Podman）。

### Socket 路径

| 运行时 | Socket 路径（宿主机） | 挂载命令 |
|--------|----------------------|----------|
| Docker | `/var/run/docker.sock` | `-v /var/run/docker.sock:/var/run/docker.sock` |
| Podman（rootful，Linux） | `/run/podman/podman.sock` | `-v /run/podman/podman.sock:/var/run/docker.sock --security-opt label=disable` |
| Podman（macOS machine） | VM 内：`/run/podman/podman.sock` | 与 rootful 相同（VM 在 `/var/run/docker.sock` 提供符号链接） |

### 示例：手动启动并挂载 Socket

```bash
# Docker
docker run -d --name hiclaw-manager \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e HICLAW_WORKER_IMAGE=hiclaw/worker-agent:latest \
  ... \
  hiclaw/manager-agent:latest

# Podman
podman run -d --name hiclaw-manager \
  -v /run/podman/podman.sock:/var/run/docker.sock \
  --security-opt label=disable \
  -e HICLAW_WORKER_IMAGE=hiclaw/worker-agent:latest \
  ... \
  hiclaw/manager-agent:latest
```

### 测试集成

测试编排器（`tests/run-all-tests.sh`）会自动检测 socket 并在可用时挂载它。

### 安全说明

挂载容器运行时 socket 会赋予容器对宿主机容器运行时的完全控制权（相当于 root 访问）。这在本地开发中是可接受的。生产环境中，建议考虑更严格的方式，如使用 Podman socket activation 并限制 API 访问权限。

## 关键技术说明

### Node.js 版本

OpenClaw 需要 **Node.js >= 22**（内部使用的 `--disable-warning` 标志需要 Node.js 21.3+）。Manager 镜像基于 `openclaw-base` 构建，该基础镜像已包含 Node.js 22。Worker Dockerfile 从构建阶段复制 Node.js 22。

- **Manager**：Node 22 由 `openclaw-base` 提供（基础镜像已内置）。
- **Worker**：从构建阶段复制的 Node 22 二进制文件替换了 Ubuntu 24.04 apt 的 Node.js 18.x（后者不支持 `--disable-warning`）。

### LLM Provider 配置

LLM Provider 直接配置在 `openclaw.json` 的 `models.providers` 字段中，无需通过网关代理：

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "qwen": {
        "baseUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "apiKey": "$HICLAW_LLM_API_KEY",
        "api": "openai-completions",
        "models": [...]
      }
    }
  }
}
```

Manager 通过环境变量 `HICLAW_LLM_PROVIDER`、`HICLAW_LLM_API_URL` 和 `HICLAW_LLM_API_KEY` 配置 LLM 访问。

### OpenClaw 技能格式

SKILL.md 文件**必须**包含 YAML front matter 块，否则 OpenClaw 无法发现它们：

```markdown
---
name: my-skill-name
description: 该技能的用途和使用时机
---

# 技能标题
...内容...
```

放置在 `<workspace>/skills/<name>/SKILL.md` 的技能会被自动发现（来源：`openclaw-workspace`）。

### OpenClaw 网关配置

`openclaw.json` 必须包含网关配置才能以无头模式运行：

```json
{
  "gateway": {
    "mode": "local",
    "port": 18799,
    "auth": { "token": "<some-token>" }
  }
}
```

缺少 `gateway.mode=local` 或 `gateway.auth.token`，OpenClaw 都会拒绝启动。

## 代码风格

- Shell 脚本：使用 `${VAR}` 语法，可复用逻辑封装为函数
- 配置模板：使用 `${VAR}` 占位符，每个字段添加注释说明
- 技能（SKILL.md）：必须包含 YAML front matter（`name` + `description`），自包含，含完整 API 参考和示例
- 测试：每个验收用例一个文件，引用共享 helper，使用断言函数

## 调试技巧

### 查看 Manager 日志

容器名称为 `hiclaw-manager`（通过 `make install`）或 `hiclaw-manager-test`（通过 `make test`）。

```bash
# 各组件日志按服务分开存储
docker exec hiclaw-manager cat /var/log/hiclaw/manager-agent.log       # 启动流程
docker exec hiclaw-manager cat /var/log/hiclaw/manager-agent-error.log # OpenClaw stderr
docker exec hiclaw-manager cat /var/log/hiclaw/tuwunel.log             # Matrix 服务器
docker exec hiclaw-manager cat /var/log/hiclaw/minio.log               # MinIO
docker exec hiclaw-manager cat /var/log/hiclaw/element-web.log         # Element Web

# OpenClaw 运行时日志（Agent 事件、工具调用、LLM 交互）
docker exec hiclaw-manager bash -c 'cat /tmp/openclaw/openclaw-*.log' | jq .
```

### 查看 Replay 对话日志

```bash
# 运行 `make replay` 后，日志会自动保存
make replay-log

# 日志目录：logs/replay/replay-{timestamp}.log
```

### 检查 OpenClaw 技能加载情况

```bash
docker exec hiclaw-manager bash -c \
  'OPENCLAW_CONFIG_PATH=/root/manager-workspace/openclaw.json openclaw skills list --json' \
  | jq '.skills[] | select(.source == "openclaw-workspace") | {name, eligible, description}'
```

### 进入容器交互式 Shell

```bash
docker exec -it hiclaw-manager bash
```

### 检查 LLM Provider 配置

```bash
# 查看 Manager 的 LLM provider 配置
docker exec hiclaw-manager cat /root/manager-workspace/openclaw.json | jq '.models.providers'

# 查看 Worker 的 LLM provider 配置
docker exec hiclaw-manager cat /root/hiclaw-fs/agents/<worker-name>/openclaw.json | jq '.models.providers'

# 验证环境变量
docker exec hiclaw-manager env | grep HICLAW_LLM
```

### 检查 MinIO 状态

```bash
mc alias set test http://localhost:9000 <user> <password>
mc ls test/hiclaw-storage/ --recursive
```

### 常见问题

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| `docker build` 期间 `git clone` 卡住 | 构建环境没有代理 | 通过 `DOCKER_BUILD_ARGS` 传递 `--build-arg http_proxy=...` |
| 健康检查返回 503 | `http_proxy` 拦截了 localhost 请求 | 设置 `no_proxy=localhost,127.0.0.1,::1` |
| OpenClaw: `SyntaxError: Unexpected reserved word` | Node.js 版本过旧 | 确保 Manager 使用 `openclaw-base` 镜像；Worker 使用构建阶段的 Node.js 22 |
| OpenClaw: `requires Node >=22.0.0` | 同上 | 同上 |
| `--disable-warning= is not allowed in NODE_OPTIONS` | Node.js < 21.3（如 Ubuntu apt 的 v18） | 确保 Worker 使用构建阶段的 Node.js 22，而非 apt 安装的版本 |
| OpenClaw: `gateway.mode=local` required | openclaw.json 中缺少网关配置 | 添加 `"gateway": {"mode": "local", ...}` |
| OpenClaw: `no token is configured` | 缺少网关认证 token | 添加 `"gateway": {"auth": {"token": "..."}}` |
| OpenClaw 未加载技能 | SKILL.md 缺少 YAML front matter | 添加 `---\nname: ...\ndescription: ...\n---` |
| Worker 无法调用 LLM | 环境变量 `HICLAW_LLM_API_KEY` 未设置 | 检查 Manager 容器的环境变量，确保 LLM API Key 已正确配置 |
| MCP Server 无法工作 | `mcporter-servers.json` 未生成或凭据缺失 | 检查 Worker 目录中的 `mcporter-servers.json`，确保相应的环境变量（如 `HICLAW_GITHUB_TOKEN`）已设置 |
