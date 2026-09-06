#!/usr/bin/env bash
set -euo pipefail

# Initialize a VPS as a private Git-over-SSH remote host.
# Usage:
#   sudo ./init-git-vps.sh "ssh-ed25519 AAAA... your-key-comment"
# Optional env vars:
#   GIT_USER=git GIT_ROOT=/srv/git DISABLE_PASSWORD=yes RESTRICT_SHELL=yes

GIT_USER="${GIT_USER:-git}"
GIT_ROOT="${GIT_ROOT:-/srv/git}"
DISABLE_PASSWORD="${DISABLE_PASSWORD:-yes}"
RESTRICT_SHELL="${RESTRICT_SHELL:-yes}"
PUBLIC_KEY="${1:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0 '<your public ssh key>'" >&2
  exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Pass your public SSH key as the first argument." >&2
  echo "Example: sudo $0 \"$(cat ~/.ssh/id_ed25519.pub)\"" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  apt-get update
  apt-get install -y git
fi

if ! id "$GIT_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Git Remote User" "$GIT_USER"
fi

mkdir -p "$GIT_ROOT"
chown -R "$GIT_USER:$GIT_USER" "$GIT_ROOT"
chmod 755 "$GIT_ROOT"

usermod -d "$GIT_ROOT" "$GIT_USER"

GIT_HOME="$(getent passwd "$GIT_USER" | cut -d: -f6)"
mkdir -p "$GIT_HOME/.ssh"
touch "$GIT_HOME/.ssh/authorized_keys"

if ! grep -Fxq "$PUBLIC_KEY" "$GIT_HOME/.ssh/authorized_keys"; then
  echo "$PUBLIC_KEY" >> "$GIT_HOME/.ssh/authorized_keys"
fi

chown -R "$GIT_USER:$GIT_USER" "$GIT_HOME/.ssh"
chmod 700 "$GIT_HOME/.ssh"
chmod 600 "$GIT_HOME/.ssh/authorized_keys"

if [[ "$RESTRICT_SHELL" == "yes" ]]; then
  GIT_SHELL="$(command -v git-shell || true)"
  if [[ -n "$GIT_SHELL" ]]; then
    grep -qxF "$GIT_SHELL" /etc/shells || echo "$GIT_SHELL" >> /etc/shells
    chsh -s "$GIT_SHELL" "$GIT_USER"
  else
    echo "Warning: git-shell not found; leaving normal shell unchanged." >&2
  fi
fi

if [[ "$DISABLE_PASSWORD" == "yes" ]]; then
  SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
  mkdir -p "$SSHD_DROPIN_DIR"
  cat > "$SSHD_DROPIN_DIR/99-git-vps-hardening.conf" <<'SSHD_CONFIG'
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD_CONFIG

  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || service sshd reload
  else
    echo "sshd config test failed; not reloading SSH." >&2
    exit 1
  fi
fi

echo "Done. Git remotes can live under: $GIT_ROOT"
echo "Create a repo with: sudo ./create-git-repo.sh myproject"
