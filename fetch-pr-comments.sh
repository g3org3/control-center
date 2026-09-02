#!/usr/bin/env bash
#
# Fetch comments for a GitHub pull request, printed as a JSON object:
#   {
#     "state":          "OPEN",    # OPEN, CLOSED, or MERGED
#     "conversation":  [ ... ],   # top-level PR comments
#     "reviewThreads": [ ... ]    # inline review comments, grouped by thread
#   }
#
# By default only unresolved review threads are shown (resolution
# status is only available through the GraphQL API, not REST).
# Conversation comments have no resolved concept and are always shown.
#
# By default, comments that already have reactions are omitted. Pass
# --reactions to include them.
#
# Usage: fetch-pr-comments.sh <owner/repo> <pr-number> [--reactions]
# Example: fetch-pr-comments.sh g3org3/quick-quinielas 67
#
# Comments from bots (netlify, github-actions, ...) are dropped.
#
# Set INCLUDE_RESOLVED=1 to show resolved review threads too.
# Set INCLUDE_BOTS=1 to keep bot comments.
#
# Requires: gh (authenticated via `gh auth login`), jq

set -euo pipefail

INCLUDE_RESOLVED="${INCLUDE_RESOLVED:-0}"
INCLUDE_BOTS="${INCLUDE_BOTS:-0}"

if [[ $# -lt 2 || $# -gt 3 || "$1" != */* || ( $# -eq 3 && "$3" != "--reactions" ) ]]; then
  echo "Usage: $(basename "$0") <owner/repo> <pr-number> [--reactions]" >&2
  exit 1
fi

owner="${1%%/*}"
repo="${1##*/}"
pr="$2"
include_reactions="0"
[[ "${3:-}" == "--reactions" ]] && include_reactions="1"

# --paginate follows reviewThreads pages via $endCursor and emits one
# JSON document per page; --slurp merges them into a single array for
# jq to flatten and filter (this gh version doesn't allow combining
# --slurp with --jq). Conversation comments repeat on every page, so
# jq reads them from the first page only; PRs with >100 conversation
# comments or >100 comments in one thread would need extra pagination
# this script doesn't do.
gh api graphql --paginate --slurp \
  -F owner="$owner" -F repo="$repo" -F pr="$pr" \
  -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          state
          comments(first: 100) {
            nodes {
              author { __typename login }
              body
              createdAt
              url
              reactionGroups {
                content
                reactors { totalCount }
              }
            }
          }
          reviewThreads(first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              isResolved
              isOutdated
              path
              line
              comments(first: 100) {
                nodes {
                  author { __typename login }
                  body
                  createdAt
                  url
                  reactionGroups {
                    content
                    reactors { totalCount }
                  }
                }
              }
            }
          }
        }
      }
    }' \
  | jq --arg include_resolved "$INCLUDE_RESOLVED" --arg include_bots "$INCLUDE_BOTS" \
      --arg include_reactions "$include_reactions" '
    def keep:
      ($include_bots == "1" or .author.__typename != "Bot") and
      ($include_reactions == "1" or ([.reactionGroups[].reactors.totalCount] | add // 0) == 0);
    def slim: {
      author: .author.login,
      createdAt,
      url,
      body,
      reactions: [
        .reactionGroups[]
        | select(.reactors.totalCount > 0)
        | { content, count: .reactors.totalCount }
      ]
    };
    if .[0].data.repository.pullRequest == null then
      "error: pull request not found\n" | halt_error(1)
    else
      { state: .[0].data.repository.pullRequest.state,
        conversation:
          [ .[0].data.repository.pullRequest.comments.nodes[]
            | select(keep) | slim ],
        reviewThreads:
          [ .[].data.repository.pullRequest.reviewThreads.nodes[]
            | select($include_resolved == "1" or (.isResolved | not))
            | { path, line, isResolved, isOutdated,
                comments: [ .comments.nodes[] | select(keep) | slim ] }
            | select(.comments | length > 0)
          ]
      }
    end'
