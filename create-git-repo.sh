#!/usr/bin/env bash
set -euo pipefail

# Create one new bare Git repo on the VPS.
# Usage:
#   sudo ./create-git-repo.sh myproject
# Optional env vars:
#   GIT_USER=git GIT_ROOT=/srv/git DEFAULT_BRANCH=main

GIT_USER="${GIT_USER:-git}"
GIT_ROOT="${GIT_ROOT:-/srv/git}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
REPO_NAME="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0 <repo-name>" >&2
  exit 1
fi

if [[ -z "$REPO_NAME" ]]; then
  echo "Usage: sudo $0 <repo-name>" >&2
  exit 1
fi

# Keep repo names simple and safe: letters, numbers, dot, underscore, dash, slash.
if [[ ! "$REPO_NAME" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$REPO_NAME" == /* ]] || [[ "$REPO_NAME" == *..* ]]; then
  echo "Invalid repo name. Use a relative name like: myproject or team/myproject" >&2
  exit 1
fi

if [[ ! "$DEFAULT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$DEFAULT_BRANCH" == /* ]] || [[ "$DEFAULT_BRANCH" == *..* ]]; then
  echo "Invalid default branch name. Use something like: main or trunk" >&2
  exit 1
fi

REPO_PATH="$GIT_ROOT/g3org3/$REPO_NAME.git"

if [[ -e "$REPO_PATH" ]]; then
  echo "Repo already exists: $REPO_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$REPO_PATH")"
if git init --bare --initial-branch="$DEFAULT_BRANCH" "$REPO_PATH" 2>/dev/null; then
  :
else
  git init --bare "$REPO_PATH"
  git --git-dir="$REPO_PATH" symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
fi
chown -R "$GIT_USER:$GIT_USER" "$REPO_PATH"

HOSTNAME_OR_IP="hermes.jagc.app"
echo "Created: $REPO_PATH"
echo "Default branch: $DEFAULT_BRANCH"
echo "Local setup:"
echo "  git remote add vps $GIT_USER@$HOSTNAME_OR_IP:g3org3/$REPO_NAME.git"
echo "  git branch -m master main"
echo "  git push -u vps $DEFAULT_BRANCH"
echo "Clone:"
echo "  git clone $GIT_USER@$HOSTNAME_OR_IP:$REPO_PATH"
