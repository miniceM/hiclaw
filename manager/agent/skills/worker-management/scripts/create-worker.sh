#!/bin/bash
# create-worker.sh - One-shot Worker creation script
#
# Automates the full Worker lifecycle: Matrix registration, room creation,
# config generation, MinIO sync, skills push, and container startup.
#
# Usage:
#   create-worker.sh --name <NAME> [--model <MODEL_ID>] [--mcp-servers s1,s2] [--skills s1,s2] [--find-skills] [--skills-api-url <URL>] [--remote]
#
# Prerequisites:
#   - SOUL.md must already exist at ~/hiclaw-fs/agents/<NAME>/SOUL.md
#   - Environment: HICLAW_REGISTRATION_TOKEN, HICLAW_MATRIX_DOMAIN,
#     HICLAW_ADMIN_USER, HICLAW_LLM_API_KEY, MANAGER_MATRIX_TOKEN

set -e
source /opt/hiclaw/scripts/lib/base.sh

# ============================================================
# Parse arguments
# ============================================================
WORKER_NAME=""
MODEL_ID=""
MCP_SERVERS=""
WORKER_SKILLS="file-sync"
REMOTE_MODE=false
ENABLE_FIND_SKILLS=false
SKILLS_API_URL=""
WORKER_RUNTIME="${HICLAW_DEFAULT_WORKER_RUNTIME:-openclaw}"   # openclaw | copaw
CONSOLE_PORT=""             # copaw only: web console port (e.g. 8088)

while [ $# -gt 0 ]; do
    case "$1" in
        --name)       WORKER_NAME="$2"; shift 2 ;;
        --model)      MODEL_ID="$2"; shift 2 ;;
        --mcp-servers) MCP_SERVERS="$2"; shift 2 ;;
        --skills)     WORKER_SKILLS="$2"; shift 2 ;;
        --find-skills) ENABLE_FIND_SKILLS=true; shift ;;
        --skills-api-url) SKILLS_API_URL="$2"; shift 2 ;;
        --remote)     REMOTE_MODE=true; shift ;;
        --runtime)    WORKER_RUNTIME="$2"; shift 2 ;;
        --console-port) CONSOLE_PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${WORKER_NAME}" ]; then
    echo "Usage: create-worker.sh --name <NAME> [--model <MODEL_ID>] [--mcp-servers s1,s2] [--skills s1,s2] [--find-skills] [--skills-api-url <URL>] [--remote] [--runtime openclaw|copaw] [--console-port <PORT>]"
    exit 1
fi

# copaw runtime supports both container and pip-installed modes
# (previously forced REMOTE_MODE=true; now containers are supported)

# If find-skills is enabled, add it to the skills list
# Fallback: if HICLAW_SKILLS_API_URL env is set and no --skills-api-url was passed, use it
if [ -z "${SKILLS_API_URL}" ] && [ -n "${HICLAW_SKILLS_API_URL}" ]; then
    SKILLS_API_URL="${HICLAW_SKILLS_API_URL}"
fi
if [ "${ENABLE_FIND_SKILLS}" = true ]; then
    if ! echo "${WORKER_SKILLS}" | grep -q '\bfind-skills\b'; then
        WORKER_SKILLS="${WORKER_SKILLS},find-skills"
    fi
fi

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
ADMIN_USER="${HICLAW_ADMIN_USER:-admin}"
CONSUMER_NAME="worker-${WORKER_NAME}"
SOUL_FILE="/root/hiclaw-fs/agents/${WORKER_NAME}/SOUL.md"

if [ ! -f "${SOUL_FILE}" ]; then
    cat << EOF
{"error": "SOUL.md not found at ${SOUL_FILE}", "hint": "Create it first with:"}
---HINT---
mkdir -p ~/hiclaw-fs/agents/${WORKER_NAME}
cat > ~/hiclaw-fs/agents/${WORKER_NAME}/SOUL.md << 'SOULEOF'
# ${WORKER_NAME} - Worker Agent

## AI Identity

**You are an AI Agent, not a human.**

- Both you and the Manager are AI agents that can work 24/7
- You do not need rest, sleep, or "off-hours"
- You can immediately start the next task after completing one
- Your time units are **minutes and hours**, not "days"

## Role
- Name: ${WORKER_NAME}
- Role: <describe the worker's role>

## Behavior
- Be helpful and concise
SOULEOF
---END---
EOF
    exit 1
fi

_fail() {
    echo '{"error": "'"$1"'"}'
    exit 1
}

# ============================================================
# Ensure credentials are available
# ============================================================
SECRETS_FILE="/data/hiclaw-secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
fi

if [ -z "${MANAGER_MATRIX_TOKEN}" ]; then
    MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD:-}"
    if [ -z "${MANAGER_PASSWORD}" ]; then
        _fail "MANAGER_MATRIX_TOKEN not set and HICLAW_MANAGER_PASSWORD not available"
    fi
    MANAGER_MATRIX_TOKEN=$(curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/login \
        -H 'Content-Type: application/json' \
        -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"manager"},"password":"'"${MANAGER_PASSWORD}"'"}' \
        2>/dev/null | jq -r '.access_token // empty')
    if [ -z "${MANAGER_MATRIX_TOKEN}" ]; then
        _fail "Failed to obtain Manager Matrix token"
    fi
    log "Obtained Manager Matrix token via login"
fi

# Resolve LLM API key from environment
if [ -z "${HICLAW_LLM_API_KEY}" ]; then
    _fail "HICLAW_LLM_API_KEY not set"
fi

# ============================================================
# Step 1: Register Matrix Account
# ============================================================
log "Step 1: Registering Matrix account for ${WORKER_NAME}..."
WORKER_USER_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"
WORKER_CREDS_FILE="/data/worker-creds/${WORKER_NAME}.env"
mkdir -p /data/worker-creds

# Reuse persisted password if available, otherwise generate new
if [ -f "${WORKER_CREDS_FILE}" ]; then
    source "${WORKER_CREDS_FILE}"
    log "  Loaded persisted credentials for ${WORKER_NAME}"
else
    WORKER_PASSWORD=$(generateKey 16)
fi
[ -z "${WORKER_MINIO_PASSWORD}" ] && WORKER_MINIO_PASSWORD=$(generateKey 24)

REG_RESP=$(curl -s -X POST http://127.0.0.1:6167/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "'"${WORKER_NAME}"'",
        "password": "'"${WORKER_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' 2>/dev/null) || true

if echo "${REG_RESP}" | jq -e '.access_token' > /dev/null 2>&1; then
    WORKER_MATRIX_TOKEN=$(echo "${REG_RESP}" | jq -r '.access_token')
    log "  Registered new account: ${WORKER_USER_ID}"
else
    # Account already exists — login with persisted password
    log "  Account exists, logging in..."
    LOGIN_RESP=$(curl -s -X POST http://127.0.0.1:6167/_matrix/client/v3/login \
        -H 'Content-Type: application/json' \
        -d '{
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": "'"${WORKER_NAME}"'"},
            "password": "'"${WORKER_PASSWORD}"'"
        }' 2>/dev/null) || true

    if echo "${LOGIN_RESP}" | jq -e '.access_token' > /dev/null 2>&1; then
        WORKER_MATRIX_TOKEN=$(echo "${LOGIN_RESP}" | jq -r '.access_token')
        log "  Logged in: ${WORKER_USER_ID}"
    else
        _fail "Failed to register or login Matrix account for ${WORKER_NAME}. If re-creating, delete /data/worker-creds/${WORKER_NAME}.env and try again."
    fi
fi

# Persist credentials for future re-creation
cat > "${WORKER_CREDS_FILE}" <<CREDS
WORKER_PASSWORD="${WORKER_PASSWORD}"
WORKER_MINIO_PASSWORD="${WORKER_MINIO_PASSWORD}"
CREDS
chmod 600 "${WORKER_CREDS_FILE}"

# ============================================================
# Step 1b: Create MinIO user with restricted permissions
# ============================================================
log "Step 1b: Creating MinIO user for ${WORKER_NAME}..."
POLICY_NAME="worker-${WORKER_NAME}"
POLICY_FILE=$(mktemp /tmp/minio-policy-XXXXXX.json)
cat > "${POLICY_FILE}" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::hiclaw-storage"],
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "agents/${WORKER_NAME}", "agents/${WORKER_NAME}/*",
            "shared", "shared/*"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::hiclaw-storage/agents/${WORKER_NAME}/*",
        "arn:aws:s3:::hiclaw-storage/shared/*"
      ]
    }
  ]
}
POLICY
mc admin user add hiclaw "${WORKER_NAME}" "${WORKER_MINIO_PASSWORD}" 2>/dev/null || true
mc admin policy remove hiclaw "${POLICY_NAME}" 2>/dev/null || true
mc admin policy create hiclaw "${POLICY_NAME}" "${POLICY_FILE}"
mc admin policy attach hiclaw "${POLICY_NAME}" --user "${WORKER_NAME}"
rm -f "${POLICY_FILE}"
log "  MinIO user ${WORKER_NAME} created with policy ${POLICY_NAME}"

# ============================================================
# Step 2: Create Matrix Room (3-party)
# ============================================================
log "Step 2: Creating Matrix room..."
ROOM_RESP=$(curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/createRoom \
    -H "Authorization: Bearer ${MANAGER_MATRIX_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{
        "name": "Worker: '"${WORKER_NAME}"'",
        "topic": "Communication channel for '"${WORKER_NAME}"'",
        "invite": [
            "@'"${ADMIN_USER}"':'"${MATRIX_DOMAIN}"'",
            "@'"${WORKER_NAME}"':'"${MATRIX_DOMAIN}"'"
        ],
        "preset": "trusted_private_chat"
    }' 2>/dev/null) || _fail "Failed to create Matrix room"

ROOM_ID=$(echo "${ROOM_RESP}" | jq -r '.room_id // empty')
if [ -z "${ROOM_ID}" ]; then
    _fail "Failed to create Matrix room: ${ROOM_RESP}"
fi
log "  Room created: ${ROOM_ID}"

# ============================================================
# Step 3: Generate openclaw.json
# ============================================================
log "Step 3: Generating openclaw.json..."
GEN_ARGS=("${WORKER_NAME}" "${WORKER_MATRIX_TOKEN}" "${HICLAW_LLM_API_KEY}")
if [ -n "${MODEL_ID}" ]; then
    GEN_ARGS+=("${MODEL_ID}")
fi
bash /opt/hiclaw/agent/skills/worker-management/scripts/generate-worker-config.sh "${GEN_ARGS[@]}"

# Generate mcporter-servers.json for local MCP servers
if [ -n "${MCP_SERVERS}" ]; then
    log "  Generating mcporter-servers.json (local mcporter)..."
    MCPORTER_JSON='{"servers":{'
    FIRST=true
    IFS=',' read -ra MCP_ARR <<< "${MCP_SERVERS}"
    for mcp_name in "${MCP_ARR[@]}"; do
        mcp_name=$(echo "${mcp_name}" | tr -d ' ')
        [ -z "${mcp_name}" ] && continue
        if [ "${FIRST}" = true ]; then FIRST=false; else MCPORTER_JSON="${MCPORTER_JSON},"; fi

        # Generate mcporter config for each MCP server (local execution)
        case "${mcp_name}" in
            github)
                if [ -n "${HICLAW_GITHUB_TOKEN}" ]; then
                    MCPORTER_JSON="${MCPORTER_JSON}\"${mcp_name}\":{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-github\"],\"env\":{\"GITHUB_PERSONAL_ACCESS_TOKEN\":\"${HICLAW_GITHUB_TOKEN}\"}}"
                fi
                ;;
            filesystem)
                MCPORTER_JSON="${MCPORTER_JSON}\"${mcp_name}\":{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-filesystem\"],\"env\":{}}"
                ;;
            *)
                # Generic MCP server - assume npx package
                MCPORTER_JSON="${MCPORTER_JSON}\"${mcp_name}\":{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-${mcp_name}\"],\"env\":{}}"
                ;;
        esac
    done
    MCPORTER_JSON="${MCPORTER_JSON}}}"
    echo "${MCPORTER_JSON}" | jq . > "/root/hiclaw-fs/agents/${WORKER_NAME}/mcporter-servers.json"
    log "  Generated mcporter-servers.json with ${MCP_SERVERS}"
fi

# ============================================================
# Step 4: Update Manager groupAllowFrom
# ============================================================
log "Step 4: Updating Manager groupAllowFrom..."
MANAGER_CONFIG="${HOME}/openclaw.json"
WORKER_MATRIX_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"
if [ -f "${MANAGER_CONFIG}" ]; then
    ALREADY_IN=$(jq -r --arg w "${WORKER_MATRIX_ID}" \
        '.channels.matrix.groupAllowFrom // [] | map(select(. == $w)) | length' \
        "${MANAGER_CONFIG}" 2>/dev/null || echo "0")
    if [ "${ALREADY_IN}" = "0" ]; then
        jq --arg w "${WORKER_MATRIX_ID}" \
            '.channels.matrix.groupAllowFrom += [$w]' \
            "${MANAGER_CONFIG}" > /tmp/manager-config-updated.json
        mv /tmp/manager-config-updated.json "${MANAGER_CONFIG}"
        log "  Added ${WORKER_MATRIX_ID} to groupAllowFrom"
    else
        log "  ${WORKER_MATRIX_ID} already in groupAllowFrom"
    fi
fi

# ============================================================
# Step 8: Sync to MinIO
# ============================================================
log "Step 5: Syncing to MinIO..."
mc mirror "/root/hiclaw-fs/agents/${WORKER_NAME}/" "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" --overwrite 2>&1 | tail -5
mc stat "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/SOUL.md" > /dev/null 2>&1 \
    || _fail "SOUL.md not found in MinIO after sync"
mc stat "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/openclaw.json" > /dev/null 2>&1 \
    || _fail "openclaw.json not found in MinIO after sync"
log "  MinIO sync verified"

# Push Worker agent files from Manager image (AGENTS.md + file-sync skill)
# Use runtime-specific file-sync skill for copaw workers
if [ "${WORKER_RUNTIME}" = "copaw" ]; then
    WORKER_AGENT_SRC="/opt/hiclaw/agent/copaw-worker-agent"
    FILESYNC_SRC="${WORKER_AGENT_SRC}/skills/file-sync"
else
    WORKER_AGENT_SRC="/opt/hiclaw/agent/worker-agent"
    FILESYNC_SRC="${WORKER_AGENT_SRC}/skills/file-sync"
fi

if [ -d "${WORKER_AGENT_SRC}" ]; then
    log "  Pushing AGENTS.md (runtime=${WORKER_RUNTIME}) to worker MinIO..."
    mc cp "${WORKER_AGENT_SRC}/AGENTS.md" \
        "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/AGENTS.md" \
        || log "  WARNING: Failed to push AGENTS.md"
    
    if [ -d "${FILESYNC_SRC}" ]; then
        log "  Pushing file-sync skill (${WORKER_RUNTIME}) to worker MinIO..."
        mc mirror "${FILESYNC_SRC}/" \
            "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/skills/file-sync/" --overwrite \
            || log "  WARNING: Failed to push file-sync skill"
        log "  Worker agent files pushed"
    else
        log "  WARNING: file-sync skill not found at ${FILESYNC_SRC}"
    fi
else
    log "  WARNING: worker-agent directory not found at ${WORKER_AGENT_SRC}"
fi

# Step 8b removed: Do NOT add the new Worker to existing Workers' groupAllowFrom.
# Workers only accept @mentions from Manager and admin by default.
# This prevents inter-worker mention loops. Enable peer mentions explicitly if needed.

# ============================================================
# Step 8.5: Update workers-registry.json and push skills
# ============================================================
log "Step 8.5: Updating workers-registry and pushing skills..."
REGISTRY_FILE="${HOME}/workers-registry.json"

# Ensure registry file exists
if [ ! -f "${REGISTRY_FILE}" ]; then
    log "  Initializing workers-registry.json..."
    echo '{"version":1,"updated_at":"","workers":{}}' > "${REGISTRY_FILE}"
fi

# Build skills JSON array from WORKER_SKILLS (comma-separated)
SKILLS_JSON="["
FIRST_SKILL=true
# Ensure file-sync is always included
SKILLS_WITH_FILESYNC="${WORKER_SKILLS}"
if ! echo "${SKILLS_WITH_FILESYNC}" | grep -q '\bfile-sync\b'; then
    SKILLS_WITH_FILESYNC="file-sync,${SKILLS_WITH_FILESYNC}"
fi
IFS=',' read -ra SKILL_ARR <<< "${SKILLS_WITH_FILESYNC}"
for skill in "${SKILL_ARR[@]}"; do
    skill=$(echo "${skill}" | tr -d ' ')
    [ -z "${skill}" ] && continue
    if [ "${FIRST_SKILL}" = true ]; then FIRST_SKILL=false; else SKILLS_JSON="${SKILLS_JSON},"; fi
    SKILLS_JSON="${SKILLS_JSON}\"${skill}\""
done
SKILLS_JSON="${SKILLS_JSON}]"

# Upsert worker entry into registry
NOW_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
WORKER_MATRIX_USER_ID="@${WORKER_NAME}:${MATRIX_DOMAIN}"

jq --arg w "${WORKER_NAME}" \
   --arg uid "${WORKER_MATRIX_USER_ID}" \
   --arg rid "${ROOM_ID}" \
   --arg ts "${NOW_TS}" \
   --arg runtime "${WORKER_RUNTIME}" \
   --argjson skills "${SKILLS_JSON}" \
   '.workers[$w] = {
     "matrix_user_id": $uid,
     "room_id": $rid,
     "runtime": $runtime,
     "skills": $skills,
     "created_at": (if .workers[$w].created_at? then .workers[$w].created_at else $ts end),
     "skills_updated_at": $ts
   } | .updated_at = $ts' \
   "${REGISTRY_FILE}" > /tmp/workers-registry-updated.json
mv /tmp/workers-registry-updated.json "${REGISTRY_FILE}"

log "  Registry updated for ${WORKER_NAME}: skills=${SKILLS_WITH_FILESYNC}"

# Push skills to worker's MinIO workspace (Worker not yet started, no notification)
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh \
    --worker "${WORKER_NAME}" --no-notify \
    || log "  WARNING: push-worker-skills.sh returned non-zero (non-fatal)"

# ============================================================
# Step 9: Start Worker
# ============================================================
DEPLOY_MODE="remote"
CONTAINER_ID=""
INSTALL_CMD=""
WORKER_STATUS="pending_install"

source /opt/hiclaw/scripts/lib/container-api.sh

_build_install_cmd() {
    # copaw workers run on the host, so use the externally-exposed gateway port.
    # openclaw workers run inside a container, so use the internal port 8080.
    local fs_domain="${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}"
    local fs_internal_endpoint="http://${fs_domain}:8080"
    local fs_external_port="${HICLAW_PORT_GATEWAY:-18080}"
    local fs_external_endpoint="http://${fs_domain}:${fs_external_port}"
    local fs_access_key="${WORKER_NAME}"
    local fs_secret_key="${WORKER_MINIO_PASSWORD}"

    if [ "${WORKER_RUNTIME}" = "copaw" ]; then
        # copaw-worker is a pip package running on the host; use external port.
        # Use Alibaba Cloud PyPI mirror for faster downloads in China.
        local cmd="pip install -i https://mirrors.aliyun.com/pypi/simple/ copaw-worker && copaw-worker"
        cmd="${cmd} --name ${WORKER_NAME}"
        cmd="${cmd} --fs ${fs_external_endpoint}"
        cmd="${cmd} --fs-key ${fs_access_key}"
        cmd="${cmd} --fs-secret ${fs_secret_key}"
        cmd="${cmd} --console-port ${CONSOLE_PORT:-8088}"
        echo "${cmd}"
        return
    fi

    local cmd="bash hiclaw-install.sh worker --name ${WORKER_NAME} --fs ${fs_internal_endpoint} --fs-key ${fs_access_key} --fs-secret ${fs_secret_key}"

    # Add find-skills related options if enabled
    if [ "${ENABLE_FIND_SKILLS}" = true ]; then
        cmd="${cmd} --find-skills"
        if [ -n "${SKILLS_API_URL}" ]; then
            cmd="${cmd} --skills-api-url ${SKILLS_API_URL}"
        fi
    fi

    echo "${cmd}"
}

# Build extra environment variables JSON for container creation
_build_extra_env() {
    local items=()
    if [ "${ENABLE_FIND_SKILLS}" = true ] && [ -n "${SKILLS_API_URL}" ]; then
        items+=("SKILLS_API_URL=${SKILLS_API_URL}")
    fi
    if [ -n "${CONSOLE_PORT}" ]; then
        items+=("HICLAW_CONSOLE_PORT=${CONSOLE_PORT}")
    fi
    if [ ${#items[@]} -eq 0 ]; then
        echo "[]"
    else
        printf '%s\n' "${items[@]}" | jq -R . | jq -s .
    fi
}

if [ "${REMOTE_MODE}" = true ]; then
    log "Step 9: Remote mode requested"
    INSTALL_CMD=$(_build_install_cmd)
elif container_api_available; then
    log "Step 9: Starting Worker container locally (runtime=${WORKER_RUNTIME})..."
    EXTRA_ENV_JSON=$(_build_extra_env)

    if [ "${WORKER_RUNTIME}" = "copaw" ]; then
        CREATE_OUTPUT=$(container_create_copaw_worker "${WORKER_NAME}" "${WORKER_NAME}" "${WORKER_MINIO_PASSWORD}" "${EXTRA_ENV_JSON}" 2>&1) || true
    else
        CREATE_OUTPUT=$(container_create_worker "${WORKER_NAME}" "${WORKER_NAME}" "${WORKER_MINIO_PASSWORD}" "${EXTRA_ENV_JSON}" 2>&1) || true
    fi

    CONTAINER_ID=$(echo "${CREATE_OUTPUT}" | tail -1)
    # Extract actual console host port (randomly assigned, may differ from container port)
    CONSOLE_HOST_PORT=$(echo "${CREATE_OUTPUT}" | grep -o 'CONSOLE_HOST_PORT=[0-9]*' | head -1 | cut -d= -f2)
    if [ -n "${CONTAINER_ID}" ] && [ ${#CONTAINER_ID} -ge 12 ]; then
        DEPLOY_MODE="local"
        if [ -n "${CONSOLE_HOST_PORT}" ]; then
            log "  Console available at host port ${CONSOLE_HOST_PORT}"
        fi
        log "  Waiting for Worker agent to be ready..."
        if [ "${WORKER_RUNTIME}" = "copaw" ]; then
            if container_wait_copaw_worker_ready "${WORKER_NAME}" 120; then
                WORKER_STATUS="ready"
                log "  CoPaw Worker agent is ready!"
            else
                WORKER_STATUS="starting"
                log "  WARNING: CoPaw Worker agent not ready within timeout (container may still be initializing)"
            fi
        else
            if container_wait_worker_ready "${WORKER_NAME}" 120; then
                WORKER_STATUS="ready"
                log "  Worker agent is ready!"
            else
                WORKER_STATUS="starting"
                log "  WARNING: Worker agent not ready within timeout (container may still be initializing)"
            fi
        fi
    else
        log "  WARNING: Container creation failed, falling back to remote mode"
        INSTALL_CMD=$(_build_install_cmd)
    fi
else
    log "Step 9: No container runtime socket available"
    INSTALL_CMD=$(_build_install_cmd)
fi

# ============================================================
# Output JSON result
# ============================================================
RESULT=$(jq -n \
    --arg name "${WORKER_NAME}" \
    --arg user_id "${WORKER_USER_ID}" \
    --arg room_id "${ROOM_ID}" \
    --arg consumer "${CONSUMER_NAME}" \
    --arg mode "${DEPLOY_MODE}" \
    --arg runtime "${WORKER_RUNTIME}" \
    --arg container_id "${CONTAINER_ID}" \
    --arg status "${WORKER_STATUS}" \
    --arg install_cmd "${INSTALL_CMD:-}" \
    --arg console_host_port "${CONSOLE_HOST_PORT:-}" \
    --argjson skills "${SKILLS_JSON}" \
    '{
        worker_name: $name,
        matrix_user_id: $user_id,
        room_id: $room_id,
        consumer: $consumer,
        runtime: $runtime,
        skills: $skills,
        mode: $mode,
        container_id: $container_id,
        status: $status,
        install_cmd: (if $install_cmd == "" then null else $install_cmd end),
        console_host_port: (if $console_host_port == "" then null else $console_host_port end)
    }')

echo "---RESULT---"
echo "${RESULT}"
