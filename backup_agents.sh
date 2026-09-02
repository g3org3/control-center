#!/usr/bin/env bash
#
# backup_agents.sh — snapshot the durable state of the coding agents on this box.
#
# Copies session history, memories, skills and configs from .claude, .codex,
# .pi, .hermes, .fx, .kiro, .vibe and .agents into ./backup_agents/<timestamp>/,
# preserving the original directory layout so a restore is a plain copy back.
#
# Deliberately skipped: installed binaries, node/venv payloads, plugin and model
# caches, downloaded browsers — all reinstallable, and together ~7 GB.
#
# Usage:
#   ./backup_agents.sh                 # snapshot to ./backup_agents/<timestamp>
#   ./backup_agents.sh --dry-run       # list what would be copied, copy nothing
#   ./backup_agents.sh --with-secrets  # also copy auth tokens / API keys
#   ./backup_agents.sh --tar           # also produce <timestamp>.tar.gz
#   ./backup_agents.sh --dest DIR      # write somewhere other than ./backup_agents

set -euo pipefail

SRC="${HOME}"
DEST_ROOT="$(pwd)/backup_agents"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
DRY_RUN=0
WITH_SECRETS=0
MAKE_TAR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --with-secrets) WITH_SECRETS=1; shift ;;
    --tar)          MAKE_TAR=1; shift ;;
    --dest)         DEST_ROOT="$(readlink -f "$2")"; shift 2 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# What to save. Paths are relative to $HOME and keep their structure in the
# snapshot. Missing paths are reported at the end, not treated as errors --
# agents come and go.
# ---------------------------------------------------------------------------
PATHS=(
  # --- Claude Code ---------------------------------------------------------
  .claude/projects                      # per-project session transcripts + memory/
  .claude/history.jsonl                 # prompt history
  .claude/settings.json
  .claude/skills                        # relative symlinks into .agents/skills
  .claude/jobs
  .claude/file-history                  # pre-edit file snapshots
  .claude/backups
  .claude/plugins/installed_plugins.json
  .claude/plugins/known_marketplaces.json

  # --- Codex ---------------------------------------------------------------
  .codex/sessions                       # rollout transcripts, by date
  .codex/session_index.jsonl
  .codex/history.jsonl
  .codex/skills
  .codex/rules
  .codex/config.toml
  .codex/hooks.json
  .codex/memories_1.sqlite              # sqlite: main file + -wal/-shm copied together
  .codex/goals_1.sqlite
  .codex/thread_history_1.sqlite
  .codex/queue_1.sqlite
  .codex/state_5.sqlite

  # --- pi ------------------------------------------------------------------
  .pi/agent/sessions
  .pi/agent/projects-memory             # per-project memory
  .pi/agent/pi-hermes-memory            # MEMORY.md / USER.md / failures.md
  .pi/agent/skills                      # relative symlinks into .agents/skills
  .pi/agent/settings.json
  .pi/agent/models.json
  .pi/agent/trust.json
  .pi/agent/run-history.jsonl

  # --- hermes --------------------------------------------------------------
  .hermes/memories                      # MEMORY.md / USER.md
  .hermes/skills
  .hermes/sessions
  .hermes/terminal-sessions
  .hermes/cron
  .hermes/hooks
  .hermes/scripts
  .hermes/shared
  .hermes/kanban
  .hermes/kanban.db
  .hermes/state.db                      # 17M: threads, tasks, agent state
  .hermes/verification_evidence.db
  .hermes/config.yaml

  # --- fx ------------------------------------------------------------------
  .fx/sessions
  .fx/history.jsonl
  .fx/usage.jsonl
  .fx/settings.json

  # --- kiro ----------------------------------------------------------------
  .kiro/sessions
  .kiro/agents
  .kiro/settings

  # --- vibe ----------------------------------------------------------------
  .vibe/vibehistory
  .vibe/config.toml
  .vibe/trusted_folders.toml

  # --- shared skill library (the real files behind the symlinks above) -----
  .agents/skills
  .agents/.skill-lock.json

  # --- subagent artifacts --------------------------------------------------
  .pi-subagents/artifacts
)

# Credentials live next to the data we want. Excluded unless --with-secrets,
# because the snapshot lands in a plain directory under $PWD.
SECRET_EXCLUDES=(
  --exclude=auth.json
  --exclude=.credentials.json
  --exclude=credentials.json
  --exclude=api-key
  --exclude=.env
  --exclude=.env.*
  --exclude=*.pem
  --exclude=*.key
)

RSYNC_ARGS=(
  -aR                     # archive, paths relative to $HOME
                          # symlinks are preserved, not dereferenced: the skill
                          # dirs are relative links into .agents/skills, which is
                          # backed up below, so they resolve again after a restore
                          # (and 25 of them are already dangling here).
  --exclude=*.lock
  --exclude=*.sock
  --exclude=node_modules
  --exclude=__pycache__
  --exclude=.git
)
[[ $WITH_SECRETS -eq 0 ]] && RSYNC_ARGS+=("${SECRET_EXCLUDES[@]}")

# ---------------------------------------------------------------------------
# Resolve the list against what actually exists, and pull in the -wal/-shm
# sidecars of every sqlite file so the copy is internally consistent.
# ---------------------------------------------------------------------------
present=()
missing=()
for p in "${PATHS[@]}"; do
  if [[ -e "${SRC}/${p}" ]]; then
    present+=("$p")
    case "$p" in
      *.sqlite|*.db)
        for side in "-wal" "-shm"; do
          [[ -e "${SRC}/${p}${side}" ]] && present+=("${p}${side}")
        done
        ;;
    esac
  else
    missing+=("$p")
  fi
done

if [[ ${#present[@]} -eq 0 ]]; then
  echo "nothing to back up: none of the listed paths exist under ${SRC}" >&2
  exit 1
fi

DEST="${DEST_ROOT}/${STAMP}"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "would copy ${#present[@]} paths from ${SRC} to ${DEST}"
  printf '  %s\n' "${present[@]}"
  [[ ${#missing[@]} -gt 0 ]] && { echo "not present (skipped):"; printf '  %s\n' "${missing[@]}"; }
  [[ $WITH_SECRETS -eq 0 ]] && echo "secrets excluded (auth.json, .credentials.json, api-key, .env, *.pem, *.key)"
  exit 0
fi

mkdir -p "$DEST"

# Hard-link unchanged files against the previous snapshot, so repeat runs cost
# only what actually changed.
if [[ -d "${DEST_ROOT}/latest" ]]; then
  RSYNC_ARGS+=(--link-dest="$(readlink -f "${DEST_ROOT}/latest")")
fi

( cd "$SRC" && rsync "${RSYNC_ARGS[@]}" "${present[@]}" "$DEST/" )

ln -sfn "$DEST" "${DEST_ROOT}/latest"

# ---------------------------------------------------------------------------
# Manifest: what landed, how big, and what was deliberately left out.
# ---------------------------------------------------------------------------
{
  echo "agent state snapshot"
  echo "taken:   $(date -Is)"
  echo "host:    $(hostname)"
  echo "source:  ${SRC}"
  echo "secrets: $([[ $WITH_SECRETS -eq 1 ]] && echo included || echo EXCLUDED)"
  echo
  echo "contents:"
  # every agent dir is hidden, so glob dotfiles explicitly
  ( cd "$DEST" && shopt -s nullglob dotglob && du -sh -- * 2>/dev/null | sort -rh )
  echo
  echo "total: $(du -sh "$DEST" | cut -f1)"
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    echo "listed but not present on this host:"
    printf '  %s\n' "${missing[@]}"
  fi
  echo
  echo "restore: copy the agent directory you want back into \$HOME, e.g."
  echo "  rsync -a ${DEST}/.claude/ \$HOME/.claude/"
  echo
  echo "note: skill dirs are symlinks into .agents/skills, which is included here."
  echo "sqlite files were copied live alongside their -wal/-shm sidecars."
  echo "For a guaranteed-consistent copy, install sqlite3 and use '.backup'."
} > "${DEST}/MANIFEST.txt"

if [[ $MAKE_TAR -eq 1 ]]; then
  tar -czf "${DEST_ROOT}/${STAMP}.tar.gz" -C "$DEST_ROOT" "$STAMP"
  echo "tarball: ${DEST_ROOT}/${STAMP}.tar.gz"
fi

echo "snapshot: ${DEST}  ($(du -sh "$DEST" | cut -f1))"
echo "latest:   ${DEST_ROOT}/latest -> ${STAMP}"
[[ $WITH_SECRETS -eq 0 ]] && echo "secrets excluded; re-run with --with-secrets to include auth tokens"
