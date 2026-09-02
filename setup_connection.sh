#!/usr/bin/env bash
#
# Restic environment picker — works in bash and zsh.
#
# Direct execution:
#   ~/.config/restic/setup_connection.sh
#   -> picks an env file, then drops you into a shell with it loaded
#
# Sourced:
#   source ~/.config/restic/setup_connection.sh
#   -> picks an env file and loads it into the current shell

RESTIC_ENV_DIR="${RESTIC_ENV_DIR:-$HOME/.config/restic}"

# --- detect sourced vs executed -------------------------------------------
_sourced=false
if [ -n "${ZSH_VERSION:-}" ]; then
  case "$ZSH_EVAL_CONTEXT" in *:file*) _sourced=true ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  [ "$0" != "$BASH_SOURCE" ] && _sourced=true
fi

# NOTE: return/exit are inlined at each error point (a helper function's
# `return` would only exit the function, not the sourced script).

# --- collect .env files ----------------------------------------------------
files=()
for f in "$RESTIC_ENV_DIR"/*.env; do
  [ -f "$f" ] && files+=("$f")
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "No .env files found in $RESTIC_ENV_DIR" >&2
  if [ "$_sourced" = true ]; then return 1; else exit 1; fi
fi

# --- print menu ------------------------------------------------------------
echo ""
echo "  Select a restic environment:"
echo "  -----------------------------"
i=1
for f in "${files[@]}"; do
  # Read RESTIC_REPOSITORY without executing the file
  repo=$(grep -E '^[[:space:]]*(export[[:space:]]+)?RESTIC_REPOSITORY=' "$f" \
         | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'")
  [ -z "$repo" ] && repo="<repository not set>"
  name=$(basename "$f")
  name="${name#restic-}"
  printf "  \033[1;36m%d)\033[0m %-28s \033[2m%s\033[0m\n" "$i" "$name" "$repo"
  i=$((i + 1))
done
echo ""

# --- ask for a choice -------------------------------------------------------
printf "  Choice [1-%d, q to cancel]: " "${#files[@]}"
read -r choice

case "$choice" in
  q|Q|"")
    echo "Cancelled." >&2
    if [ "$_sourced" = true ]; then return 1; else exit 1; fi
    ;;
esac

# --- resolve the selection (portable: no array indexing) --------------------
selected=""
i=1
for f in "${files[@]}"; do
  [ "$i" -eq "$choice" ] 2>/dev/null && selected="$f"
  i=$((i + 1))
done

if [ -z "$selected" ]; then
  echo "Invalid choice: $choice" >&2
  if [ "$_sourced" = true ]; then return 1; else exit 1; fi
fi

# --- load it ----------------------------------------------------------------
# shellcheck disable=SC1090
. "$selected"

loaded_name=$(basename "$selected")
loaded_name="${loaded_name#restic-}"
printf '\n  \033[1;32m✓ Loaded:\033[0m %s\n' "$loaded_name"
printf '    RESTIC_REPOSITORY=%s\n' "${RESTIC_REPOSITORY:-<unset>}"
printf '\n'

unset files f repo i choice selected loaded_name name

if [ "$_sourced" = true ]; then
  unset _sourced
  return 0
fi

# Executed directly: variables can't cross into the parent shell,
# so spawn an interactive shell with the env loaded.
unset _sourced
echo "Dropping into a shell with this restic env (type 'exit' to leave)."
exec "${SHELL:-/bin/bash}" -i
