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
#
# Safeguards (the plan job holds credentials and executes PR code):
#   - PR must come from a branch in $REPO itself, never a fork
#   - run must be bound to this PR: same head SHA, branch, and PR number
#   - run's triggering actor (the pusher) must also be on the allowlist
approve_pr_plan() {
  local pr="$1" pr_json head_sha head_ref cross allowlist_json run_id env_ids id runs
  pr_json=$("$GH_BIN" pr view "$pr" --repo "$REPO" --json headRefOid,headRefName,isCrossRepository) || return 0
  head_sha=$(echo "$pr_json" | "$JQ_BIN" -r .headRefOid)
  head_ref=$(echo "$pr_json" | "$JQ_BIN" -r .headRefName)
  cross=$(echo "$pr_json" | "$JQ_BIN" -r .isCrossRepository)
  [[ -z "$head_sha" || "$head_sha" == "null" ]] && return 0
  if [[ "$cross" != "false" ]]; then
    log "Skipping pr-plan approval for PR #$pr (head is from a fork)"
    return 0
  fi

  allowlist_json=$(printf '%s\n' "${INCLUDED_AUTHORS[@]}" | "$JQ_BIN" -R . | "$JQ_BIN" -s .)

  # Runs awaiting approval for exactly this head SHA, bound to this PR
  runs=$("$GH_BIN" api "repos/$REPO/actions/runs?status=waiting&head_sha=$head_sha&per_page=100" \
          | "$JQ_BIN" -r --arg repo "$REPO" --arg ref "$head_ref" --argjson pr "$pr" --argjson allow "$allowlist_json" '
              .workflow_runs[]
              | select(.event == "pull_request")
              | select(.head_repository.full_name == $repo and .head_branch == $ref)
              | select([.pull_requests[]?.number] | index($pr))
              | select(.triggering_actor.login as $a | $allow | index($a))
              | .id') || return 0

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
