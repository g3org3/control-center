#!/usr/bin/env bash
#
# Wrapper for fetching agent-ready issues or PR comments.
#
# Usage: github-agent-workflow.sh <owner|-> <repo> [pr-number] [--reactions]
# Example: github-agent-workflow.sh g3org3 quick-quinielas
#          github-agent-workflow.sh - quick-quinielas 67
#          github-agent-workflow.sh - quick-quinielas 67 --reactions
#
# If owner is "-" the fallback owner is "g3org3".
# When no PR number is provided, this runs fetch-agent-ready-issues.sh.
# When a PR number is provided, this runs fetch-pr-comments.sh.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $(basename "$0") <owner|-> <repo> [pr-number] [--reactions]" >&2
  exit 1
fi

owner="$1"
repo="$2"
pr_number="${3:-}"
reactions_flag="${4:-}"

if [[ -n "$reactions_flag" && "$reactions_flag" != "--reactions" ]]; then
  echo "Unknown option: $reactions_flag" >&2
  exit 1
fi

if [[ "$pr_number" == "--reactions" ]]; then
  echo "--reactions requires a PR number" >&2
  exit 1
fi

if [[ "$owner" == "-" ]]; then
  owner="g3org3"
fi

full_repo="${owner}/${repo}"

if [[ -z "$pr_number" ]]; then
  exec "$(dirname "$0")/fetch-agent-ready-issues.sh" "$full_repo"
else
  if [[ -n "$reactions_flag" ]]; then
    exec "$(dirname "$0")/fetch-pr-comments.sh" "$full_repo" "$pr_number" "$reactions_flag"
  else
    exec "$(dirname "$0")/fetch-pr-comments.sh" "$full_repo" "$pr_number"
  fi
fi
