#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

GH_BIN="${GH_BIN:-$(command -v gh || true)}"
JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"

if [[ -z "$GH_BIN" ]]; then
  log "gh not found on PATH: $PATH"
  echo "[!] gh command not found on PATH: $PATH" >&2
  exit 1
fi

if [[ -z "$JQ_BIN" ]]; then
  log "jq not found on PATH: $PATH"
  echo "[!] jq command not found on PATH: $PATH" >&2
  exit 1
fi

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
USER_LOGIN=$("$GH_BIN" api user --jq .login)

# Only these authors are eligible for auto-approval
INCLUDED_AUTHORS=(
  "dficker"
  "jahzlariosa"
  "careydayrit"
  "danreb"
  "dqlopez"
  "dylanbaumann"
  "rainercedric23"
  "michaelvgonzaga"
  "ersonjn"
  "gagandeeply"
  "aminulpantheon"
  "shelleycabarrubias"
  "khairulanam-pantheon"
  "sharlenerozario8"
  "jinnueljosevitug"
  "tristanhipolito"
  "arving-pantheon"
  "jrannelv"
  "Brix-Adrian-Cruz"
  "ravenloveriel"
  "elsamson"
  "v0jpantheon"
  "kirrrk"
  "rogeliocastillojr"
  "mateuszklorek"
  "bogusz-gorkiewicz"
)

PLAN_ENVIRONMENT="pr-plan"

# Approve pending "pr-plan" environment deployments for a PR's current head SHA.
# Only called for allowlisted authors: the plan runs PR code with credentials.
approve_pr_plan() {
  local pr="$1" head_sha run_id env_ids id runs
  head_sha=$("$GH_BIN" pr view "$pr" --repo "$REPO" --json headRefOid --jq .headRefOid) || return 0
  [[ -z "$head_sha" ]] && return 0

  # Runs awaiting approval for exactly this head SHA
  runs=$("$GH_BIN" api "repos/$REPO/actions/runs?status=waiting&head_sha=$head_sha&per_page=100" \
          --jq '.workflow_runs[] | select(.event == "pull_request" or .event == "pull_request_target") | .id') || return 0

  for run_id in $runs; do
    env_ids=$("$GH_BIN" api "repos/$REPO/actions/runs/$run_id/pending_deployments" \
              --jq '.[] | select(.environment.name == "'"$PLAN_ENVIRONMENT"'" and .current_user_can_approve == true) | .environment.id') || continue
    for id in $env_ids; do
      if "$GH_BIN" api -X POST "repos/$REPO/actions/runs/$run_id/pending_deployments" \
           -F "environment_ids[]=$id" -f state=approved \
           -f comment="Auto approved using cse-agcdn-approve" >/dev/null; then
        log "Approved $PLAN_ENVIRONMENT deployment for PR #$pr (run $run_id, sha ${head_sha:0:7})"
      else
        log "Failed to approve $PLAN_ENVIRONMENT deployment for PR #$pr (run $run_id)"
      fi
    done
  done
}

# Build candidate PR list (not authored by you and newer than 5 days)
prs=$("$GH_BIN" pr list \
      --repo "$REPO" \
      --state open \
      --json number,author,createdAt \
      --jq '.[] | select(.author.login != "'"$USER_LOGIN"'" and ((now - (.createdAt | fromdate)) < (60*60*24*5))) | .number' \
      || echo "")

# Exit early if no PRs to process
[ -z "$prs" ] && log "No candidate PRs found after author/date filtering" && exit 0

# Loop through each PR and approve if needed
for pr in $prs; do
  # Skip if PR is merged or closed (just to be safe)
  state=$("$GH_BIN" pr view "$pr" --repo "$REPO" --json state --jq .state)
  [[ "$state" != "OPEN" ]] && log "Skipping PR #$pr (state: $state)" && continue

  author=$("$GH_BIN" pr view "$pr" --repo "$REPO" --json author --jq '.author.login')

  included=false
  for allowed in "${INCLUDED_AUTHORS[@]}"; do
    if [[ "$author" == "$allowed" ]]; then
      included=true
      break
    fi
  done

  if [[ "$included" != true ]]; then
    log "Skipping PR #$pr (author not in include list: $author)"
    continue
  fi

  # Release the pr-plan gate (independent of review state below)
  approve_pr_plan "$pr"

  # Fetch all reviews
  reviews=$("$GH_BIN" pr view "$pr" --repo "$REPO" --json reviews --jq '.reviews')

  # Count distinct APPROVED reviewers (excluding author and self)
  num_others_approved=$(echo "$reviews" | "$JQ_BIN" '[.[] | select(.state == "APPROVED" and .author.login != "'$USER_LOGIN'") | .author.login] | unique | length')

  log "PR #$pr currently has $num_others_approved approval(s) from other reviewers"

  # Only approve if fewer than 2 other reviewers have approved
  if [[ "$num_others_approved" -ge 2 ]]; then
    log "Skipping PR #$pr (already has $num_others_approved approvals)"
    continue
  fi

  # Find the last review from the user
  latest_user_review=$(echo "$reviews" | "$JQ_BIN" -r '[.[] | select(.author.login == "'$USER_LOGIN'")] | sort_by(.submittedAt) | last')
  latest_state=$(echo "$latest_user_review" | "$JQ_BIN" -r '.state // empty')

  # Skip if the latest review was APPROVED
  if [[ "$latest_state" == "APPROVED" ]]; then
    log "Skipping PR #$pr (already approved by you)"
    continue
  fi

  # Submit your approval
  "$GH_BIN" pr review "$pr" \
    --repo "$REPO" \
    --approve \
    --body "Auto approved using cse-agcdn-approve"
  log "Approved PR #$pr"
done
