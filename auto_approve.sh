#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Logging configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/autoapprove.log"
ERRFILE="$SCRIPT_DIR/autoapprove.err"
exec 2>>"$ERRFILE"
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

log "Starting auto_approve.sh"

# Configuration
REPO="pantheon-systems/tf-agcdn"
USER_LOGIN=$(gh api user --jq .login)
LABELS=("add-site")

# Fetch open PR numbers not authored by you, not older than 5 days, and matching any required label
prs=$(gh pr list \
      --repo "$REPO" \
      --state open \
      $(printf -- '--label %q ' "${LABELS[@]}") \
      --json number,author,createdAt \
      --jq '.[] | select(.author.login != "'$USER_LOGIN'" and ((now - (.createdAt | fromdate)) < (60*60*24*5))) | .number' \
      || echo "")

# Exit early if no PRs to process
[ -z "$prs" ] && log "No matching PRs found" && exit 0

# Loop through each PR and approve if needed
for pr in $prs; do
  # Skip if PR is merged or closed (just to be safe)
  state=$(gh pr view "$pr" --repo "$REPO" --json state --jq .state)
  [[ "$state" != "OPEN" ]] && log "Skipping PR #$pr (state: $state)" && continue

  # Fetch all reviews
  reviews=$(gh pr view "$pr" --repo "$REPO" --json reviews --jq '.reviews')

  # Count distinct APPROVED reviewers (excluding author and self)
  num_others_approved=$(echo "$reviews" | jq '[.[] | select(.state == "APPROVED" and .author.login != "'$USER_LOGIN'") | .author.login] | unique | length')

  # Only approve if fewer than 2 other reviewers have approved
  if [[ "$num_others_approved" -ge 2 ]]; then
    log "Skipping PR #$pr (already $num_others_approved approvals)"
    continue
  fi

  # Find the last review from the user
  latest_user_review=$(echo "$reviews" | jq -r '[.[] | select(.author.login == "'$USER_LOGIN'")] | sort_by(.submittedAt) | last')
  latest_state=$(echo "$latest_user_review" | jq -r '.state // empty')

  # Skip if the latest review was APPROVED
  if [[ "$latest_state" == "APPROVED" ]]; then
    log "Skipping PR #$pr (already approved by you)"
    continue
  fi

  # Submit your approval
  gh pr review "$pr" \
    --repo "$REPO" \
    --approve \
    --body "Auto approved using cse-agcdn-approve"
  log "Approved PR #$pr"
done
