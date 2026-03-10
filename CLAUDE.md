# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

HiClaw 是一个开源的 AI Agent 团队协作系统,基于 OpenClaw 构建。系统通过 IM(Matrix 协议)实现多 Agent 协作,具备 human-in-the-loop 监督能力和企业级安全特性。

### 核心组件

- **Manager Agent**: 协调者,负责创建 Worker、分配任务、监控进度
- **Worker Agent**: 任务执行者,通过 Matrix 房间与 Manager 和人类通信
- **Tuwunel (Matrix)**: IM 服务器,所有 Agent 和人类之间的通信
- **MinIO**: HTTP 文件系统,集中式存储,Worker 无状态
- **Element Web**: Web 客户端

### 安全模型

**安全设计**：Worker 通过环境变量注入获得 LLM API Key 和 MCP 凭据，不存储在配置文件中。即使 Worker 容器被攻击，攻击者只能访问运行时内存，无法获取持久化的凭证。

## 常用命令

### 构建和测试

```bash
# 构建所有镜像(本地原生架构)
make build

# 仅构建 Manager 或 Worker
make build-manager
make build-worker
make build-copaw-worker

# 运行完整集成测试
export HICLAW_LLM_API_KEY="your-api-key"
make test

# 运行指定测试
make test TEST_FILTER="01 02 03"

# 跳过构建直接测试(加快迭代)
make test SKIP_BUILD=1

# 快速冒烟测试(仅 test-01)
make test-quick
```

### 安装和卸载

```bash
# 快速安装(使用默认配置,仅需 API Key)
HICLAW_LLM_API_KEY="sk-xxx" make install

# 自定义安装
HICLAW_LLM_API_KEY="sk-xxx" \
HICLAW_LLM_PROVIDER="openai" \
HICLAW_DEFAULT_MODEL="gpt-4o" \
make install

# 卸载
make uninstall

# 向 Manager 发送任务
make replay TASK="创建一个名为 alice 的 Worker 用于前端开发"
make replay  # 交互模式
```

### 镜像推送

```bash
# 推送多架构镜像(amd64 + arm64)
make push VERSION=0.1.0 REGISTRY=ghcr.io REPO=nicepkg/hiclaw

# 推送到本地镜像仓库(开发用,不推荐用于生产)
make push-native VERSION=dev
```

## 代码架构

### 项目结构

```
hiclaw/
├── manager/              # Manager Agent 容器(一体化: Tuwunel + MinIO + Element Web)
│   ├── agent/           # Agent 配置和技能
│   │   ├── SOUL.md      # Manager 身份和规则
│   │   ├── HEARTBEAT.md # 心跳检查清单
│   │   ├── skills/      # Manager 的核心技能(9个)
│   │   └── worker-skills/ # 推送给 Worker 的技能定义
│   ├── configs/         # 初始化配置模板
│   ├── scripts/         # 启动脚本库
│   │   ├── init/        # 容器启动脚本(supervisord 管理)
│   │   └── lib/         # 共享库(base.sh, container-api.sh)
│   └── Dockerfile       # 多阶段构建定义
├── worker/              # OpenClaw Worker 容器(轻量级)
│   ├── agent/
│   │   └── skills/      # Worker 技能(github-operations 等)
│   ├── scripts/
│   └── Dockerfile
├── copaw/               # CoPaw Worker 容器(Python,更轻量 ~100MB)
├── install/             # 一键安装脚本
├── scripts/             # 实用脚本(replay-task.sh)
├── tests/               # 集成测试套件(10个测试用例)
├── docs/                # 用户文档
└── design/              # 内部设计文档和 API 规范
```

### Manager 核心技能

位于 `manager/agent/skills/`,每个技能包含 SKILL.md 和可选的脚本/参考:

1. **task-management**: 任务管理
2. **worker-management**: Worker 管理(创建、删除、更新)
3. **mcp-server-management**: MCP 服务器管理
4. **matrix-server-management**: Matrix 服务器管理
5. **task-coordination**: 任务协调
6. **project-management**: 项目管理
7. **model-switch**: 模型切换
8. **worker-model-switch**: Worker 模型切换

### 关键设计模式

1. **所有通信在 Matrix 房间中**: 人类 + Manager + Worker 都在同一房间,人类看到一切并可随时介入
2. **集中式文件系统**: 所有 Agent 配置和状态存储在 MinIO,Worker 无状态,可随意销毁重建
3. **统一凭证管理**: Worker 使用一个 Consumer key-auth token 同时访问 LLM 和 MCP Server,由 Manager 控制权限
4. **技能即文档**: 每个 SKILL.md 是自包含的参考,告诉 Agent 如何使用 API 或工具

### 环境变量

完整列表见 `manager/scripts/init/start-manager-agent.sh`,关键变量:

- `HICLAW_LLM_API_KEY`: LLM API 密钥(必需)
- `HICLAW_LLM_PROVIDER`: LLM 提供商(qwen/openai/deepseek 等)
- `HICLAW_DEFAULT_MODEL`: 默认模型
- `HICLAW_ADMIN_USER` / `HICLAW_ADMIN_PASSWORD`: Matrix 管理员凭据
- `HICLAW_DATA_DIR`: 数据目录(默认 `~/.hiclaw-data`)
- `HICLAW_WORKSPACE_DIR`: Manager 工作空间(默认 `~/hiclaw-manager`)
- `HICLAW_MOUNT_SOCKET`: 是否挂载容器运行时 socket(默认 1)

## 变更日志政策

任何影响构建镜像内容的更改——即在 `manager/`、`worker/`、`copaw/` 或 `openclaw-base/` 下的修改——**必须**在提交前记录到 `changelog/current.md`。

格式:每个逻辑更改一个要点,带提交哈希:
```markdown
- feat(manager): add new skill for task distribution ([a1b2c3d](https://github.com/nicepkg/hiclaw/commit/a1b2c3d))
- fix(worker): correct heartbeat interval calculation ([e4f5g6h](https://github.com/nicepkg/hiclaw/commit/e4f5g6h))
```

## 开发注意事项

### 技术要求

- **Node.js 版本**: OpenClaw 需要 **Node.js >= 22**(Manager 由 `openclaw-base` 提供,Worker 从构建阶段复制)
- **容器运行时**: Docker 或 Podman(支持 socket 挂载用于直接创建 Worker)
- **构建工具**: Make(通过 Makefile 统一接口)

### Agent 行为修改

Agent 行为由 Markdown 文件定义,而非代码:
- **Manager SOUL**: `manager/agent/SOUL.md`
- **Manager 心跳**: `manager/agent/HEARTBEAT.md`
- **技能**: `manager/agent/skills/*/SKILL.md` 和 `manager/agent/worker-skills/*/SKILL.md`

**重要**: SKILL.md 文件**必须**包含 YAML front matter 块,否则 OpenClaw 无法发现:

```markdown
---
name: my-skill-name
description: 该技能的用途和使用时机
---

# 技能标题
...内容...
```

### 容器运行时 Socket

Manager 容器启动时如果挂载了宿主机的容器运行时 socket,可以直接创建 Worker 容器(本地部署无需人工干预):

| 运行时 | Socket 路径(宿主机) |
|--------|---------------------|
| Docker | `/var/run/docker.sock` |
| Podman (rootful, Linux) | `/run/podman/podman.sock` |
| Podman (macOS machine) | `/run/podman/podman.sock`(VM 提供符号链接) |

Worker 创建逻辑见 `manager/scripts/lib/container-api.sh`,通过 Docker 兼容的 REST API 同时支持 Docker 和 Podman。

### 网络代理配置(中国大陆)

构建镜像需要访问 GitHub 和 npm 镜像源,通常需要代理:

```bash
# 宿主机代理(重要: 将 localhost 排除在代理之外)
export http_proxy="http://127.0.0.1:1087"
export https_proxy="http://127.0.0.1:1087"
export no_proxy="localhost,127.0.0.1,::1,local,169.254/16"

# Docker 构建代理(通过 host.docker.internal 访问宿主机)
make build-manager DOCKER_BUILD_ARGS="--build-arg http_proxy=http://host.docker.internal:1087 --build-arg https_proxy=http://host.docker.internal:1087"
```

### 代码风格

- **Shell 脚本**: 使用 `${VAR}` 语法,可复用逻辑封装为函数
- **配置模板**: 使用 `${VAR}` 占位符,每个字段添加注释说明
- **技能(SKILL.md)**: 必须包含 YAML front matter(`name` + `description`),自包含,含完整 API 参考和示例
- **测试**: 每个验收用例一个文件,引用共享 helper,使用断言函数

### 测试覆盖

- 10 个集成测试用例覆盖主要场景
- 测试 01-07: 基础功能(无需额外配置)
- 测试 08-10: GitHub 操作(需要 `HICLAW_GITHUB_TOKEN`)
- 所有测试必须在提交前通过(`make test`)

## 调试技巧

### 查看 Manager 日志

```bash
# 各组件日志按服务分开存储
docker exec hiclaw-manager cat /var/log/hiclaw/manager-agent.log     # 启动日志
docker exec hiclaw-manager cat /var/log/hiclaw/manager-agent-error.log  # OpenClaw Agent stderr
docker exec hiclaw-manager cat /var/log/hiclaw/tuwunel.log

# OpenClaw 运行时日志(Agent 事件、工具调用、LLM 交互)
docker exec hiclaw-manager bash -c 'cat /tmp/openclaw/openclaw-*.log' | jq .
```

### 检查 OpenClaw 技能加载

```bash
docker exec hiclaw-manager bash -c \
  'OPENCLAW_CONFIG_PATH=/root/manager-workspace/openclaw.json openclaw skills list --json' \
  | jq '.skills[] | select(.source == "openclaw-workspace") | {name, eligible, description}'
```

### 常见问题

| 现象 | 原因 | 解决方案 |
|------|------|----------|
| `docker build` 期间 `git clone` 卡住 | 构建环境没有代理 | 通过 `DOCKER_BUILD_ARGS` 传递 `--build-arg http_proxy=...` |
| 健康检查返回 503 | `http_proxy` 拦截了 localhost 请求 | 设置 `no_proxy=localhost,127.0.0.1,::1` |
| OpenClaw: `requires Node >=22.0.0` | Node.js 版本过旧 | 确保 Manager 使用 `openclaw-base` 镜像;Worker 使用构建阶段的 Node.js 22 |
| OpenClaw: `gateway.mode=local` required | openclaw.json 中缺少网关配置 | 添加 `"gateway": {"mode": "local", ...}` |
| OpenClaw 未加载技能 | SKILL.md 缺少 YAML front matter | 添加 `---\nname: ...\ndescription: ...\n---` |

## 参考文档

- **AGENTS.md**: AI Agent 代码导航指南(非常重要)
- **docs/architecture.md**: 系统架构深入解析
- **docs/development.md**: 完整开发指南(本文档的扩展版本)
- **docs/quickstart.md**: 端到端快速开始指南
- **docs/manager-guide.md**: Manager 配置指南
- **docs/worker-guide.md**: Worker 部署和故障排除
- **design/**: 内部设计文档和 API 规范
