# hiclaw-manager-agent

All-in-one Manager Agent container. Includes:

- **Tuwunel Matrix Server** (port 6167): Agent IM communication
- **MinIO** (port 9000 API, 9001 console): Centralized HTTP file system
- **Element Web** (via Nginx on port 8088): Browser-based IM client
- **Manager Agent** (OpenClaw): Coordinates Workers, manages credentials, assigns tasks
- **mc mirror**: Bidirectional file sync between MinIO and local filesystem

## Build

```bash
# Via Makefile (recommended)
make build-manager

# Or directly
docker build -t hiclaw/manager-agent:latest .
```

## Run

Use the installation script instead of running directly:

```bash
../install/hiclaw-install.sh manager
```

## Directory Structure

```
manager/
├── Dockerfile              # Multi-stage build
├── supervisord.conf        # Process orchestration (priority-ordered)
├── scripts/
│   ├── init/               # Container startup scripts (supervisord)
│   │   ├── start-*.sh      # Component startup scripts
│   │   └── setup-higress.sh # Higress route/consumer/MCP init
│   └── lib/                # Shared libraries
│       ├── base.sh         # Shared utilities (waitForService, generateKey, log)
│       └── container-api.sh # Docker/Podman REST API helpers
├── agent/                  # Manager agent definition (synced to MinIO)
│   ├── AGENTS.md           # Agent instructions
│   ├── SOUL.md             # Manager personality and rules
│   ├── HEARTBEAT.md        # Periodic check routine
│   └── skills/             # Each skill is self-contained
│       ├── worker-management/
│       │   ├── SKILL.md
│       │   ├── scripts/    # create-worker.sh, generate-worker-config.sh
│       │   └── references/ # worker-openclaw.json.tmpl
│       ├── mcp-server-management/
│       │   ├── SKILL.md
│       │   └── references/ # mcp-github.yaml
│       └── matrix-server-management/
│           └── SKILL.md
├── configs/
│   └── manager-openclaw.json.tmpl  # Manager OpenClaw config template
└── tests/
    └── smoke-test.sh       # Post-startup health check
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HICLAW_ADMIN_USER` | Yes | - | Human admin Matrix username |
| `HICLAW_ADMIN_PASSWORD` | Yes | - | Human admin password |
| `HICLAW_MANAGER_PASSWORD` | Yes | - | Manager Agent Matrix password |
| `HICLAW_REGISTRATION_TOKEN` | Yes | - | Tuwunel registration token |
| `HICLAW_MATRIX_DOMAIN` | No | `matrix-local.hiclaw.io:8080` | Matrix server domain |
| `HICLAW_MATRIX_CLIENT_DOMAIN` | No | `matrix-client-local.hiclaw.io` | Element Web domain |
| `HICLAW_AI_GATEWAY_DOMAIN` | No | `aigw-local.hiclaw.io` | AI Gateway domain (for LLM and MCP) |
| `HICLAW_FS_DOMAIN` | No | `fs-local.hiclaw.io` | HTTP file system domain |
| `HICLAW_LLM_PROVIDER` | Yes | - | LLM provider name |
| `HICLAW_DEFAULT_MODEL` | Yes | - | Default LLM model ID |
| `HICLAW_LLM_API_KEY` | Yes | - | LLM API key |
| `HICLAW_MINIO_USER` | Yes | - | MinIO root user |
| `HICLAW_MINIO_PASSWORD` | Yes | - | MinIO root password |
| `HICLAW_MANAGER_GATEWAY_KEY` | Yes | - | Manager's Higress consumer key |
| `HICLAW_GITHUB_TOKEN` | No | - | GitHub PAT for MCP Server |
