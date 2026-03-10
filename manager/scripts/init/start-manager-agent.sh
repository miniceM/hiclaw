#!/bin/bash
# start-manager-agent.sh - Initialize and start the Manager Agent
# This is the last component to start (priority 800).
# It waits for all dependencies, creates Matrix users,
# creates symlinks for host directory access, and launches OpenClaw.

source /opt/hiclaw/scripts/lib/base.sh

# ============================================================
# Set timezone from TZ env var
# ============================================================
if [ -n "${TZ}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    log "Timezone set to ${TZ}"
fi

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"

# ============================================================
# Create symlink for host directory access
# If /host-share is mounted, create a symlink using the original host's HOME path
# ============================================================
if [ -d "/host-share" ]; then
    # Determine the original host's home directory path for consistent access
    # The user can set HOST_ORIGINAL_HOME via environment variable if needed
    ORIGINAL_HOST_HOME="${HOST_ORIGINAL_HOME:-$HOME}"

    # Only create the symlink if it won't conflict with existing paths in the container
    if [ ! -e "${ORIGINAL_HOST_HOME}" ] && [ "${ORIGINAL_HOST_HOME}" != "/" ] && [ "${ORIGINAL_HOST_HOME}" != "/root" ] && [ "${ORIGINAL_HOST_HOME}" != "/data" ] && [ "${ORIGINAL_HOST_HOME}" != "/host-share" ]; then
        # Create parent directories if they don't exist
        mkdir -p "$(dirname "${ORIGINAL_HOST_HOME}")"

        # Create symlink from original host home path to the mounted host share
        ln -sfn /host-share "${ORIGINAL_HOST_HOME}"
        log "Created symlink: ${ORIGINAL_HOST_HOME} -> /host-share"
        log "Host files now accessible at: ${ORIGINAL_HOST_HOME}/"
    else
        log "Skipping symlink creation to avoid conflict with existing path: ${ORIGINAL_HOST_HOME}"
        # Create a fallback symlink with a different name
        ln -sfn /host-share /root/host-home
        log "Created fallback symlink: /root/host-home -> /host-share"
    fi
else
    log "Host share directory (/host-share) not found, skipping symlink creation"
fi

# Add local domains to /etc/hosts so they resolve inside the container
HOSTS_DOMAINS="${MATRIX_DOMAIN%%:*} ${HICLAW_MATRIX_CLIENT_DOMAIN:-matrix-client-local.hiclaw.io} ${HICLAW_FS_DOMAIN:-fs-local.hiclaw.io}"
if ! grep -q "${MATRIX_DOMAIN%%:*}" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${HOSTS_DOMAINS}" >> /etc/hosts
    log "Added local domains to /etc/hosts"
fi

# ============================================================
# Auto-generate secrets if not provided via environment
# Persisted to /data so they survive container restart
# ============================================================
SECRETS_FILE="/data/hiclaw-secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
    log "Loaded persisted secrets from ${SECRETS_FILE}"
fi

if [ -z "${HICLAW_MANAGER_PASSWORD}" ]; then
    export HICLAW_MANAGER_PASSWORD="$(generateKey 16)"
    log "Auto-generated HICLAW_MANAGER_PASSWORD"
fi

# Persist secrets so they survive supervisord restart
mkdir -p /data
cat > "${SECRETS_FILE}" <<EOF
export HICLAW_MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD}"
EOF
chmod 600 "${SECRETS_FILE}"

# ============================================================
# Wait for all dependencies
# ============================================================
waitForService "Tuwunel" "127.0.0.1" 6167 120
waitForHTTP "Tuwunel Matrix API" "http://127.0.0.1:6167/_tuwunel/server_version" 120
waitForService "MinIO" "127.0.0.1" 9000 120

# ============================================================
# Initialize / upgrade Manager workspace (local only, not synced to MinIO)
# First boot: full init via upgrade-builtins.sh
# Subsequent boots: compare image version; upgrade only if changed
# ============================================================
mkdir -p /root/manager-workspace

IMAGE_VERSION=$(cat /opt/hiclaw/agent/.builtin-version 2>/dev/null || echo "unknown")
INSTALLED_VERSION=$(cat /root/manager-workspace/.builtin-version 2>/dev/null || echo "")

if [ ! -f /root/manager-workspace/.initialized ]; then
    log "First boot: initializing manager workspace..."
    bash /opt/hiclaw/scripts/init/upgrade-builtins.sh
    touch /root/manager-workspace/.initialized
    log "Manager workspace initialized (version: ${IMAGE_VERSION})"
elif [ "${IMAGE_VERSION}" != "${INSTALLED_VERSION}" ] || [ "${IMAGE_VERSION}" = "latest" ]; then
    log "Upgrade detected: ${INSTALLED_VERSION} -> ${IMAGE_VERSION}${IMAGE_VERSION:+ (latest: always upgrade)}"
    bash /opt/hiclaw/scripts/init/upgrade-builtins.sh
    log "Manager workspace upgraded to version: ${IMAGE_VERSION}"
else
    log "Workspace up to date (version: ${IMAGE_VERSION})"
fi

# Wait for mc mirror initialization (shared + worker data in /root/hiclaw-fs/)
log "Waiting for MinIO storage initialization..."
while [ ! -f /root/hiclaw-fs/.initialized ]; do sleep 2; done
log "MinIO storage initialized"

# ============================================================
# Register Matrix users via Registration API (single-step, no UIAA)
# ============================================================
log "Registering human admin Matrix account..."
curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "'"${HICLAW_ADMIN_USER}"'",
        "password": "'"${HICLAW_ADMIN_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' > /dev/null 2>&1 || log "Admin account may already exist"

log "Registering Manager Agent Matrix account..."
curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/register \
    -H 'Content-Type: application/json' \
    -d '{
        "username": "manager",
        "password": "'"${HICLAW_MANAGER_PASSWORD}"'",
        "auth": {
            "type": "m.login.registration_token",
            "token": "'"${HICLAW_REGISTRATION_TOKEN}"'"
        }
    }' > /dev/null 2>&1 || log "Manager account may already exist"

# Get Manager Agent's Matrix access token
log "Obtaining Manager Matrix access token..."
_LOGIN_RESPONSE=$(curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/login \
    -H 'Content-Type: application/json' \
    -d '{
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": "manager"},
        "password": "'"${HICLAW_MANAGER_PASSWORD}"'"
    }' 2>&1)
_LOGIN_EXIT=$?
log "Matrix login HTTP exit code: ${_LOGIN_EXIT}"
log "Matrix login response: ${_LOGIN_RESPONSE}"

MANAGER_TOKEN=$(echo "${_LOGIN_RESPONSE}" | jq -r '.access_token' 2>/dev/null)

if [ -z "${MANAGER_TOKEN}" ] || [ "${MANAGER_TOKEN}" = "null" ]; then
    log "ERROR: Failed to obtain Manager Matrix token (exit=${_LOGIN_EXIT})"
    log "ERROR: Login response was: ${_LOGIN_RESPONSE}"
    exit 1
fi
log "Manager Matrix token obtained (token prefix: ${MANAGER_TOKEN:0:10}...)"

# ============================================================
# Generate Manager Agent openclaw.json from template
# ============================================================
log "Generating Manager openclaw.json..."
export MANAGER_MATRIX_TOKEN="${MANAGER_TOKEN}"

# Resolve LLM provider and API URL from environment variables
LLM_PROVIDER="${HICLAW_LLM_PROVIDER:-qwen}"
LLM_API_URL="${HICLAW_LLM_API_URL:-}"
if [ -z "${LLM_API_URL}" ]; then
    case "${LLM_PROVIDER}" in
        qwen) LLM_API_URL="https://dashscope.aliyuncs.com/compatible-mode/v1" ;;
        openai) LLM_API_URL="https://api.openai.com/v1" ;;
        *)    LLM_API_URL="" ;;
    esac
fi
export HICLAW_LLM_PROVIDER="${LLM_PROVIDER}"
export HICLAW_LLM_API_URL="${LLM_API_URL}"

# Resolve model parameters based on model name
MODEL_NAME="${HICLAW_DEFAULT_MODEL:-qwen3.5-plus}"
case "${MODEL_NAME}" in
    gpt-5.3-codex|gpt-5-mini|gpt-5-nano)
        export MODEL_CONTEXT_WINDOW=400000 MODEL_MAX_TOKENS=128000 ;;
    claude-opus-4-6)
        export MODEL_CONTEXT_WINDOW=1000000 MODEL_MAX_TOKENS=128000 ;;
    claude-sonnet-4-6)
        export MODEL_CONTEXT_WINDOW=1000000 MODEL_MAX_TOKENS=64000 ;;
    claude-haiku-4-5)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=64000 ;;
    qwen3.5-plus)
        export MODEL_CONTEXT_WINDOW=960000 MODEL_MAX_TOKENS=64000 ;;
    deepseek-chat|deepseek-reasoner|kimi-k2.5)
        export MODEL_CONTEXT_WINDOW=256000 MODEL_MAX_TOKENS=128000 ;;
    glm-5|MiniMax-M2.5)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=128000 ;;
    *)
        export MODEL_CONTEXT_WINDOW=200000 MODEL_MAX_TOKENS=128000 ;;
esac
export MODEL_REASONING=true

# Resolve input modalities: only vision-capable models get "image"
case "${MODEL_NAME}" in
    gpt-5.4|gpt-5.3-codex|gpt-5-mini|gpt-5-nano|claude-opus-4-6|claude-sonnet-4-6|claude-haiku-4-5|qwen3.5-plus|kimi-k2.5)
        export MODEL_INPUT='["text", "image"]' ;;
    *)
        export MODEL_INPUT='["text"]' ;;
esac

log "Model: ${MODEL_NAME} (provider=${LLM_PROVIDER}, api=${LLM_API_URL}, context=${MODEL_CONTEXT_WINDOW}, maxTokens=${MODEL_MAX_TOKENS}, reasoning=${MODEL_REASONING}, input=${MODEL_INPUT})"

if [ -f /root/manager-workspace/openclaw.json ]; then
    log "Manager openclaw.json already exists, updating dynamic fields only (preserving user customizations)..."
    jq --arg token "${MANAGER_TOKEN}" \
       --arg provider "${LLM_PROVIDER}" \
       --arg apiUrl "${LLM_API_URL}" \
       --arg model "${MODEL_NAME}" \
       --argjson ctx "${MODEL_CONTEXT_WINDOW}" \
       --argjson max "${MODEL_MAX_TOKENS}" \
       --argjson input "${MODEL_INPUT}" \
       '.channels.matrix.accessToken = $token | .hooks.token = $token
        | .models.providers[$provider].baseUrl = $apiUrl
        | .models.providers[$provider].models[0].id = $model
        | .models.providers[$provider].models[0].name = $model
        | .models.providers[$provider].models[0].contextWindow = $ctx
        | .models.providers[$provider].models[0].maxTokens = $max
        | .models.providers[$provider].models[0].input = $input
        | .agents.defaults.model.primary = ($provider + "/" + $model)' \
       /root/manager-workspace/openclaw.json > /tmp/openclaw.json.tmp && \
        mv /tmp/openclaw.json.tmp /root/manager-workspace/openclaw.json
    # Verify the token was written correctly
    _written_token=$(jq -r '.channels.matrix.accessToken' /root/manager-workspace/openclaw.json 2>/dev/null)
    if [ -z "${_written_token}" ] || [ "${_written_token}" = "null" ]; then
        log "ERROR: Matrix token was not written correctly to openclaw.json (got: ${_written_token})"
    else
        log "Matrix token written to openclaw.json (prefix: ${_written_token:0:10}...)"
    fi
else
    log "Manager openclaw.json not found, generating from template..."
    envsubst < /opt/hiclaw/configs/manager-openclaw.json.tmpl > /root/manager-workspace/openclaw.json
    _written_token=$(jq -r '.channels.matrix.accessToken' /root/manager-workspace/openclaw.json 2>/dev/null)
    log "Matrix token written from template (prefix: ${_written_token:0:10}...)"
fi

# ============================================================
# Detect container runtime socket (for direct Worker creation)
# ============================================================
source /opt/hiclaw/scripts/lib/container-api.sh
if container_api_available; then
    log "Container runtime socket detected at ${CONTAINER_SOCKET} — direct Worker creation enabled"
    export HICLAW_CONTAINER_RUNTIME="socket"
else
    log "No container runtime socket found — Worker creation will output install commands"
    export HICLAW_CONTAINER_RUNTIME="none"
fi

# ============================================================
# Recreate Worker containers as needed after Manager restart.
# Manager IP may change on restart; Workers use ExtraHosts pointing to Manager IP,
# so any worker whose ExtraHosts IP no longer matches must be recreated.
# ============================================================
if container_api_available; then
    REGISTRY_FILE="/root/manager-workspace/workers-registry.json"
    _manager_ip=$(container_get_manager_ip)
    if [ -f "${REGISTRY_FILE}" ]; then
        for _worker_name in $(jq -r '.workers | keys[]' "${REGISTRY_FILE}" 2>/dev/null); do
            [ -z "${_worker_name}" ] && continue
            _status=$(container_status_worker "${_worker_name}")
            if [ "${_status}" = "running" ]; then
                # Check if ExtraHosts IP still matches current Manager IP.
                # If ExtraHosts is empty the worker uses real DNS — no recreate needed.
                _inspect=$(_api GET "/containers/${WORKER_CONTAINER_PREFIX}${_worker_name}/json" 2>/dev/null)
                _extra_hosts_len=$(echo "${_inspect}" | jq -r '.HostConfig.ExtraHosts | length' 2>/dev/null)
                if [ -z "${_extra_hosts_len}" ] || [ "${_extra_hosts_len}" = "0" ]; then
                    log "Worker running (no ExtraHosts, real DNS): ${_worker_name}, skipping"
                    continue
                fi
                _worker_ip=$(echo "${_inspect}" | jq -r '.HostConfig.ExtraHosts[0]' 2>/dev/null | cut -d: -f2)
                if [ "${_worker_ip}" = "${_manager_ip}" ]; then
                    log "Worker running with current Manager IP (${_manager_ip}): ${_worker_name}, skipping"
                    continue
                fi
                log "Worker running but Manager IP changed (${_worker_ip} -> ${_manager_ip}): ${_worker_name}, recreating..."
            else
                # Container missing or stopped — always recreate.
                log "Worker container ${_status}: ${_worker_name}, recreating..."
            fi
            _creds_file="/data/worker-creds/${_worker_name}.env"
            if [ -f "${_creds_file}" ]; then
                source "${_creds_file}"
                container_create_worker "${_worker_name}" "${_worker_name}" "${WORKER_MINIO_PASSWORD}" 2>&1 \
                    && log "  Recreated worker: ${_worker_name}" \
                    || log "  WARNING: Failed to recreate worker: ${_worker_name}"
            else
                log "  WARNING: No credentials found for ${_worker_name} (${_creds_file} missing), skipping"
            fi
        done
    fi
fi

# ============================================================
# Notify workers of builtin updates if upgrade happened
# Builtin files (AGENTS.md, skills) are already synced by upgrade-builtins.sh
# ============================================================
if [ -f /root/manager-workspace/.upgrade-pending-worker-notify ]; then
    log "Notifying workers about builtin updates..."
    REGISTRY_FILE="/root/manager-workspace/workers-registry.json"
    if [ -f "${REGISTRY_FILE}" ]; then
        for _worker_name in $(jq -r '.workers | keys[]' "${REGISTRY_FILE}" 2>/dev/null); do
            [ -z "${_worker_name}" ] && continue
            _room_id=$(jq -r --arg w "${_worker_name}" '.workers[$w].room_id // empty' "${REGISTRY_FILE}" 2>/dev/null)
            if [ -n "${_room_id}" ]; then
                _worker_id="@${_worker_name}:${MATRIX_DOMAIN}"
                _txn_id="upgrade-$(date +%s%N)"
                _msg="@${_worker_name}:${MATRIX_DOMAIN} Manager upgraded builtin files (AGENTS.md, skills). Please use your file-sync skill to sync the latest config."
                curl -sf -X PUT \
                    "http://127.0.0.1:6167/_matrix/client/v3/rooms/${_room_id}/send/m.room.message/${_txn_id}" \
                    -H "Authorization: Bearer ${MANAGER_TOKEN}" \
                    -H 'Content-Type: application/json' \
                    -d "{\"msgtype\":\"m.text\",\"body\":\"${_msg}\",\"m.mentions\":{\"user_ids\":[\"${_worker_id}\"]}}" \
                    > /dev/null 2>&1 \
                    && log "  Notified ${_worker_name}" \
                    || log "  WARNING: Failed to notify ${_worker_name}"
            fi
        done
    fi
    rm -f /root/manager-workspace/.upgrade-pending-worker-notify
fi

# ============================================================
# Start OpenClaw Manager Agent
# ============================================================
log "Starting Manager Agent (OpenClaw)..."

# HOME is already set to /root/manager-workspace via docker run -e HOME=...
export OPENCLAW_CONFIG_PATH="/root/manager-workspace/openclaw.json"

# Symlink to default OpenClaw config path so CLI commands find the config
mkdir -p "${HOME}/.openclaw"
ln -sf "/root/manager-workspace/openclaw.json" "${HOME}/.openclaw/openclaw.json"

# Ensure host credential symlinks exist under HOME so agent CLIs find them
if [ -d "/host-share" ]; then
    for config_dir in .claude .gemini .qoder; do
        [ -d "/host-share/${config_dir}" ] && ln -sfn "/host-share/${config_dir}" "${HOME}/${config_dir}"
    done
    [ -f "/host-share/.gitconfig" ] && ln -sf "/host-share/.gitconfig" "${HOME}/.gitconfig"
fi

log "HOME=${HOME} (manager-workspace, host-mounted)"
cd "${HOME}"
exec openclaw gateway run --verbose --force
