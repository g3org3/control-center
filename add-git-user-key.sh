#!/usr/bin/env bash
set -euo pipefail

# Add an SSH public key for someone who should have Git remote access.
# Usage:
#   sudo ./add-git-user-key.sh "ssh-ed25519 AAAA... user-comment"
# Optional env var:
#   GIT_USER=git

GIT_USER="${GIT_USER:-git}"
PUBLIC_KEY="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0 '<public ssh key>'" >&2
  exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Pass the user's public SSH key as the first argument." >&2
  echo "Example: sudo $0 \"ssh-ed25519 AAAAC3... george@laptop\"" >&2
  exit 1
fi

if ! id "$GIT_USER" >/dev/null 2>&1; then
  echo "User does not exist: $GIT_USER" >&2
  echo "Run init-git-vps.sh first." >&2
  exit 1
fi

case "$PUBLIC_KEY" in
  ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
  *)
    echo "This does not look like a valid SSH public key." >&2
    echo "Expected it to start with ssh-ed25519, ssh-rsa, or ecdsa-sha2-*" >&2
    exit 1
    ;;
esac

GIT_HOME="$(getent passwd "$GIT_USER" | cut -d: -f6)"
SSH_DIR="$GIT_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"

if grep -Fxq "$PUBLIC_KEY" "$AUTH_KEYS"; then
  echo "Key already exists for user: $GIT_USER"
else
  echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
  echo "Added key for user: $GIT_USER"
fi

chown -R "$GIT_USER:$GIT_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

echo "Done. This key can now clone/push repos as: $GIT_USER@hermes.jagc.app:g3org3/repo_name"
