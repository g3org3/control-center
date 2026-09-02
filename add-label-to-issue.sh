#!/usr/bin/env bash
#
# Add one or both workflow labels to a GitHub issue.
#
# Usage: add-label-to-issue.sh <owner/repo> <issue-number> <label> [label ...]
# Labels: agent-ready, in-progress
#
# Examples:
#   add-label-to-issue.sh g3org3/quick-quinielas 42 agent-ready
#   add-label-to-issue.sh g3org3/quick-quinielas 42 in-progress agent-ready
#
# Requires: gh (authenticated via `gh auth login`)

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <owner/repo> <issue-number> <agent-ready|in-progress> [...]" >&2
  exit 1
}

[[ $# -ge 3 && "$1" == */* && "$2" =~ ^[0-9]+$ ]] || usage

repo="$1"
issue_number="$2"
shift 2

labels=()
for label in "$@"; do
  case "$label" in
    agent-ready|in-progress)
      labels+=("$label")
      ;;
    *)
      echo "Unsupported label: $label" >&2
      usage
      ;;
  esac
done

# gh accepts a comma-separated list for --add-label.
printf -v label_list '%s,' "${labels[@]}"
label_list="${label_list%,}"

gh issue edit "$issue_number" --repo "$repo" --add-label "$label_list"
