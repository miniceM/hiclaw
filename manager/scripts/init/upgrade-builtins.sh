#!/bin/bash
# upgrade-builtins.sh - Upgrade Manager workspace builtin files and sync Worker builtins to MinIO
#
# Called by start-manager-agent.sh on first boot or when image version changes.
# Strategy:
#   - .md files: merge (replace builtin section, preserve user content below end marker)
#   - scripts/ and references/ dirs: always overwrite from image
#   - Worker builtins: sync directly to each registered worker's MinIO workspace
#   - Workers no longer need to pull from shared/builtins/worker/ on startup

set -e

AGENT_SRC="/opt/hiclaw/agent"
WORKSPACE="${HOME}/manager-workspace"
REGISTRY="${WORKSPACE}/workers-registry.json"
IMAGE_VERSION=$(cat "${AGENT_SRC}/.builtin-version" 2>/dev/null || echo "unknown")

BUILTIN_START="<!-- hiclaw-builtin-start -->"
BUILTIN_END="<!-- hiclaw-builtin-end -->"
BUILTIN_HEADER='<!-- hiclaw-builtin-start -->
> ⚠️ **DO NOT EDIT** this section. It is managed by HiClaw and will be automatically
> replaced on upgrade. To customize, add your content **after** the
> `<!-- hiclaw-builtin-end -->` marker below.
'

log() {
    echo "[upgrade-builtins $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ============================================================
# update_builtin_section <target_file> <source_file>
#
# Merges the builtin section from source into target:
#   - If target doesn't exist: write marker-wrapped source content
#   - If target has markers: replace builtin section, preserve user content
#   - If target has no markers (old install): prepend markers, keep old content as user zone
# ============================================================
update_builtin_section() {
    local target="$1"
    local source="$2"

    if [ ! -f "${source}" ]; then
        log "  WARNING: source not found: ${source}, skipping"
        return 0
    fi

    mkdir -p "$(dirname "${target}")"

    if [ ! -f "${target}" ]; then
        # First time: write full builtin content with markers
        log "  Creating: ${target}"
        printf '%s\n' "${BUILTIN_HEADER}" > "${target}"
        cat "${source}" >> "${target}"
        printf '\n%s\n' "${BUILTIN_END}" >> "${target}"
        return 0
    fi

    if grep -q 'hiclaw-builtin-start' "${target}" 2>/dev/null; then
        # Has markers: check if builtin content actually changed
        # Filter out the header block (start marker + all > warning lines + blank line)
        local current_builtin new_builtin
        current_builtin=$(awk '/hiclaw-builtin-start/{found=1; skip=1; next} skip && /^>/{next} skip && /^$/{skip=0; next} /hiclaw-builtin-end/{found=0; skip=0} found{print}' "${target}")
        new_builtin=$(cat "${source}")
        if [ "${current_builtin}" = "${new_builtin}" ]; then
            log "  Up to date: ${target}"
            return 0
        fi
        # Extract user content after end marker; strip stray marker lines (e.g., from old corrupted files)
        local user_content
        user_content=$(awk '/hiclaw-builtin-end/{found=1; next} found{print}' "${target}" | grep -v 'hiclaw-builtin')
        {
            printf '%s\n' "${BUILTIN_HEADER}"
            cat "${source}"
            printf '\n%s\n' "${BUILTIN_END}"
            if [ -n "${user_content}" ]; then
                printf '\n%s\n' "${user_content}"
            fi
        } > "${target}.tmp"
        mv "${target}.tmp" "${target}"
        log "  Updated builtin section: ${target}"
    else
        # Old install without markers: preserve existing content as user zone
        log "  Adding markers to legacy file: ${target}"
        local old_content
        old_content=$(cat "${target}")
        {
            printf '%s\n' "${BUILTIN_HEADER}"
            cat "${source}"
            printf '\n%s\n' "${BUILTIN_END}"
            printf '\n%s\n' "${old_content}"
        } > "${target}.tmp"
        mv "${target}.tmp" "${target}"
    fi
}

# ============================================================
# Step 1: Upgrade Manager workspace .md files (14 files)
# ============================================================
log "Step 1: Upgrading Manager workspace .md files..."

update_builtin_section "${WORKSPACE}/SOUL.md" "${AGENT_SRC}/SOUL.md"
update_builtin_section "${WORKSPACE}/HEARTBEAT.md" "${AGENT_SRC}/HEARTBEAT.md"
update_builtin_section "${WORKSPACE}/AGENTS.md" "${AGENT_SRC}/AGENTS.md"

for skill_dir in "${AGENT_SRC}/skills"/*/; do
    skill_name=$(basename "${skill_dir}")
    src="${skill_dir}SKILL.md"
    dst="${WORKSPACE}/skills/${skill_name}/SKILL.md"
    [ -f "${src}" ] && update_builtin_section "${dst}" "${src}"
done

for skill_dir in "${AGENT_SRC}/worker-skills"/*/; do
    skill_name=$(basename "${skill_dir}")
    src="${skill_dir}SKILL.md"
    dst="${WORKSPACE}/worker-skills/${skill_name}/SKILL.md"
    [ -f "${src}" ] && update_builtin_section "${dst}" "${src}"
done

# ============================================================
# Step 2: Always overwrite scripts/ and references/ from image
# ============================================================
log "Step 2: Syncing scripts and references..."

for skill_dir in "${AGENT_SRC}/skills"/*/; do
    skill_name=$(basename "${skill_dir}")
    if [ -d "${skill_dir}scripts" ]; then
        mkdir -p "${WORKSPACE}/skills/${skill_name}/scripts"
        cp -r "${skill_dir}scripts/." "${WORKSPACE}/skills/${skill_name}/scripts/"
        find "${WORKSPACE}/skills/${skill_name}/scripts" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
        log "  Synced scripts: skills/${skill_name}/scripts/"
    fi
    if [ -d "${skill_dir}references" ]; then
        mkdir -p "${WORKSPACE}/skills/${skill_name}/references"
        cp -r "${skill_dir}references/." "${WORKSPACE}/skills/${skill_name}/references/"
        log "  Synced references: skills/${skill_name}/references/"
    fi
done

for skill_dir in "${AGENT_SRC}/worker-skills"/*/; do
    skill_name=$(basename "${skill_dir}")
    if [ -d "${skill_dir}scripts" ]; then
        mkdir -p "${WORKSPACE}/worker-skills/${skill_name}/scripts"
        cp -r "${skill_dir}scripts/." "${WORKSPACE}/worker-skills/${skill_name}/scripts/"
        find "${WORKSPACE}/worker-skills/${skill_name}/scripts" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
        log "  Synced scripts: worker-skills/${skill_name}/scripts/"
    fi
done

# Sync workers-registry.json template if not yet present (never overwrite user data)
if [ ! -f "${WORKSPACE}/workers-registry.json" ]; then
    if [ -f "${AGENT_SRC}/workers-registry.json" ]; then
        cp "${AGENT_SRC}/workers-registry.json" "${WORKSPACE}/workers-registry.json"
        log "  Initialized workers-registry.json"
    fi
fi

# ============================================================
# Step 3: Publish Worker builtin templates to MinIO shared/builtins/worker/
# ============================================================
log "Step 3: Publishing Worker builtins to MinIO..."

WORKER_AGENT_SRC="${AGENT_SRC}/worker-agent"

if [ -d "${WORKER_AGENT_SRC}" ] && mc alias ls hiclaw > /dev/null 2>&1; then
    # Publish AGENTS.md (pure builtin content without markers, for comparison)
    # We publish the marker-wrapped version so Workers can update their copy directly
    mc cp "${WORKER_AGENT_SRC}/AGENTS.md" \
        "hiclaw/hiclaw-storage/shared/builtins/worker/AGENTS.md" 2>/dev/null \
        && log "  Published: shared/builtins/worker/AGENTS.md" \
        || log "  WARNING: Failed to publish AGENTS.md to MinIO (MinIO may not be ready yet)"

    # Publish file-sync skill (builtin, lives in worker-agent/)
    if [ -f "${WORKER_AGENT_SRC}/skills/file-sync/SKILL.md" ]; then
        mc cp "${WORKER_AGENT_SRC}/skills/file-sync/SKILL.md" \
            "hiclaw/hiclaw-storage/shared/builtins/worker/skills/file-sync/SKILL.md" 2>/dev/null || true
    fi
    if [ -d "${WORKER_AGENT_SRC}/skills/file-sync/scripts" ]; then
        mc mirror "${WORKER_AGENT_SRC}/skills/file-sync/scripts/" \
            "hiclaw/hiclaw-storage/shared/builtins/worker/skills/file-sync/scripts/" --overwrite 2>/dev/null \
            && log "  Published: shared/builtins/worker/skills/file-sync/scripts/" \
            || log "  WARNING: Failed to publish file-sync scripts to MinIO"
    fi

    # Publish all worker-skills directories to builtins so Workers can refresh assigned skills
    for _skill_dir in "${AGENT_SRC}/worker-skills"/*/; do
        _skill_name=$(basename "${_skill_dir}")
        mc mirror "${_skill_dir}" \
            "hiclaw/hiclaw-storage/shared/builtins/worker/skills/${_skill_name}/" --overwrite 2>/dev/null \
            && log "  Published: shared/builtins/worker/skills/${_skill_name}/" \
            || true
    done
else
    log "  Skipping MinIO publish (worker-agent dir not found or mc not configured)"
fi

# ============================================================
# Step 4: Sync builtins to all registered workers' MinIO workspaces
# This ensures workers get builtin updates directly in their workspace,
# eliminating the need for workers to pull from shared/builtins/worker/ on startup.
# ============================================================
log "Step 4: Syncing builtins to registered workers' workspaces..."

if [ -d "${WORKER_AGENT_SRC}" ] && mc alias ls hiclaw > /dev/null 2>&1; then
    # Get list of registered workers
    REGISTERED_WORKERS=""
    if [ -f "${REGISTRY}" ]; then
        REGISTERED_WORKERS=$(jq -r '.workers | keys[]' "${REGISTRY}" 2>/dev/null || true)
    fi

    if [ -n "${REGISTERED_WORKERS}" ]; then
        for _worker_name in ${REGISTERED_WORKERS}; do
            [ -z "${_worker_name}" ] && continue
            log "  Syncing builtins to worker: ${_worker_name}"

            # Push AGENTS.md
            mc cp "${WORKER_AGENT_SRC}/AGENTS.md" \
                "hiclaw/hiclaw-storage/agents/${_worker_name}/AGENTS.md" 2>/dev/null \
                && log "    Updated AGENTS.md" \
                || log "    WARNING: Failed to sync AGENTS.md"

            # Push all builtin skills from worker-agent/skills/ (these are default for all workers)
            if [ -d "${WORKER_AGENT_SRC}/skills" ]; then
                for _skill_dir in "${WORKER_AGENT_SRC}/skills"/*/; do
                    [ ! -d "${_skill_dir}" ] && continue
                    _skill_name=$(basename "${_skill_dir}")
                    mc mirror "${_skill_dir}" \
                        "hiclaw/hiclaw-storage/agents/${_worker_name}/skills/${_skill_name}/" --overwrite 2>/dev/null \
                        && log "    Updated builtin skill: ${_skill_name}" \
                        || log "    WARNING: Failed to sync builtin skill ${_skill_name}"
                done
            fi

            # Push all worker-skills that the worker has assigned
            for _skill_name in $(jq -r --arg w "${_worker_name}" \
                '.workers[$w].skills // [] | .[]' "${REGISTRY}" 2>/dev/null); do
                [ -z "${_skill_name}" ] && continue

                _skill_src="${AGENT_SRC}/worker-skills/${_skill_name}"
                if [ -d "${_skill_src}" ]; then
                    mc mirror "${_skill_src}/" \
                        "hiclaw/hiclaw-storage/agents/${_worker_name}/skills/${_skill_name}/" --overwrite 2>/dev/null \
                        && log "    Updated skill: ${_skill_name}" \
                        || log "    WARNING: Failed to sync skill ${_skill_name}"
                fi
            done
        done
        log "  Synced builtins to $(echo "${REGISTERED_WORKERS}" | wc -w) worker(s)"
    else
        log "  No workers registered, skipping sync"
    fi
else
    log "  Skipping worker sync (worker-agent dir not found or mc not configured)"
fi

# ============================================================
# Step 5: Write installed version
# ============================================================
echo "${IMAGE_VERSION}" > "${WORKSPACE}/.builtin-version"
log "Step 5: Installed version: ${IMAGE_VERSION}"

# ============================================================
# Step 6: Mark that workers need builtin update notification
# ============================================================
# Check if any workers are registered; if so, mark for post-startup notification
if [ -f "${REGISTRY}" ] && jq -e '.workers | length > 0' "${REGISTRY}" > /dev/null 2>&1; then
    touch "${WORKSPACE}/.upgrade-pending-worker-notify"
    log "Step 6: Marked for worker skill notification (workers registered)"
else
    log "Step 6: No workers registered, skipping notification mark"
fi

log "Upgrade complete (version: ${IMAGE_VERSION})"
