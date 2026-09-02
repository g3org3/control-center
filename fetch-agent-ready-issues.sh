#!/usr/bin/env bash
#
# Fetch all open issues labeled "agent-ready" from a GitHub repo,
# printed as a JSON array sorted from oldest to newest.
#
# Usage: fetch-agent-ready-issues.sh [--in-progress] <owner/repo>
# Example: fetch-agent-ready-issues.sh anthropics/claude-code
#          fetch-agent-ready-issues.sh --in-progress anthropics/claude-code
#
# Requires: gh (authenticated via `gh auth login`)

set -euo pipefail

# Override with e.g. `LABEL=bug fetch-agent-ready-issues.sh owner/repo`
LABEL="${LABEL:-agent-ready}"

include_in_progress=false
repo=""

for arg in "$@"; do
  case "$arg" in
    --in-progress)
      include_in_progress=true
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      echo "Usage: $(basename "$0") [--in-progress] <owner/repo>" >&2
      exit 1
      ;;
    *)
      if [[ -n "$repo" ]]; then
        echo "Usage: $(basename "$0") [--in-progress] <owner/repo>" >&2
        exit 1
      fi
      repo="$arg"
      ;;
  esac
done

if [[ -z "$repo" || "$repo" != */* ]]; then
  echo "Usage: $(basename "$0") [--in-progress] <owner/repo>" >&2
  exit 1
fi

# The issues API also returns pull requests, so drop anything with a
# `pull_request` key. Server-side params handle the label filter and
# oldest-first ordering; --paginate --slurp merges all pages into one
# array of arrays, which python3 flattens (this gh version doesn't
# allow combining --slurp with --jq).
gh api \
  --paginate --slurp \
  "repos/${repo}/issues?state=open&labels=${LABEL}&sort=created&direction=asc&per_page=100" \
  | INCLUDE_IN_PROGRESS="$include_in_progress" REPO="$repo" python3 -c '
import json, os, subprocess, sys

pages = json.load(sys.stdin)
include_in_progress = os.environ["INCLUDE_IN_PROGRESS"] == "true"
issues = [
    issue
    for page in pages
    for issue in page
    if "pull_request" not in issue
    and (
        include_in_progress
        or "in-progress" not in {
            label.get("name") for label in issue.get("labels", [])
        }
    )
]

prs_by_issue = {issue["number"]: [] for issue in issues}
if issues:
    owner, name = os.environ["REPO"].split("/", 1)
    issue_fields = " ".join(
        "issue_{0}: issue(number: {0}) {{ "
        "closedByPullRequestsReferences(first: 100) {{ nodes {{ number state }} }} }}"
        .format(issue["number"])
        for issue in issues
    )
    query = (
        "query($owner: String!, $name: String!) { "
        "repository(owner: $owner, name: $name) { "
        f"{issue_fields}"
        "} }"
    )
    result = subprocess.run(
        [
            "gh", "api", "graphql",
            "-f", f"owner={owner}",
            "-f", f"name={name}",
            "-f", f"query={query}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    repository = json.loads(result.stdout)["data"]["repository"]
    for issue in issues:
        nodes = repository["issue_{}".format(issue["number"])][
            "closedByPullRequestsReferences"
        ]["nodes"]
        prs_by_issue[issue["number"]] = [
            {"state": pr["state"], "num": pr["number"]}
            for pr in nodes
        ]

trimmed = [
    {
        "url": issue.get("url"),
        "id": issue.get("id"),
        "number": issue.get("number"),
        "title": issue.get("title"),
        "user": issue.get("user", {}).get("login") if issue.get("user") else None,
        "labels": [
            label.get("name")
            for label in issue.get("labels", [])
        ],
        "prs": prs_by_issue[issue["number"]],
        "state": issue.get("state"),
        "assignee": issue.get("assignee", {}).get("login") if issue.get("assignee") else None,
        "created_at": issue.get("created_at"),
        "updated_at": issue.get("updated_at"),
        "closed_at": issue.get("closed_at"),
        "body": issue.get("body"),
    }
    for issue in issues
]

json.dump(trimmed, sys.stdout, indent=2)
print()
'
