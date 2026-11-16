# Auto Approve PRs with GitHub CLI on macOS

This setup uses two scripts:

- `auto_approve.sh`: Automatically approves eligible pull requests in a GitHub repository.
- `manage_autoapprove.sh`: Installs and manages the background execution using `launchd` on macOS.

## What It Approves

The `auto_approve.sh` script will automatically approve a pull request if:

- It is labeled with one of the labels defined in the script (e.g., `add-site`)
- You are not the author
- It was created in the last 5 days
- Fewer than 2 distinct reviewers have approved it
- Your latest review is not already an approval

## pr-plan Deployment Approval

For PRs from authors in `INCLUDED_AUTHORS`, the script also approves pending
`pr-plan` environment deployments (the Terraform plan gate) on the PR's current
head SHA. It only touches runs in `waiting` status for `pull_request` events, and
only when you are an allowed reviewer of the environment. Because the plan runs PR
code with credentials, it additionally requires that the PR is not from a fork, the
run is bound to that PR (same head SHA, branch, and PR number), and the run's
triggering actor is also in `INCLUDED_AUTHORS` (so bot-triggered runs, e.g.
`agcdn-ci-automerge[bot]`, are not auto-approved). This is independent of
the review-approval rules above, so it runs even if you already approved the PR.
A new push creates a new SHA and a new gate, which is approved on the next run.

## Installation

1. Clone or download the scripts `auto_approve.sh` and `manage_autoapprove.sh`
2. Run the install script:

   ```bash
   ./manage_autoapprove.sh install
   ```

This will:

- Install required dependencies (`gh`, `jq`)
- Prompt you to authenticate with GitHub CLI if needed
- Create a `launchd` agent
- Start the background job that runs every 60 seconds

## Managing the Job

Use `manage_autoapprove.sh` to control the background job:

```bash
./manage_autoapprove.sh start      # Start the job manually (if not already running)
./manage_autoapprove.sh stop       # Stop the job
./manage_autoapprove.sh reload     # Stop and restart the job
./manage_autoapprove.sh uninstall  # Remove the job and launch agent
./manage_autoapprove.sh status     # Check if the job is loaded and active
./manage_autoapprove.sh logs       # Tail the log and error output
```

## Logs

Logs are written to the same directory as the scripts:

```bash
./autoapprove.log
./autoapprove.err
```

To monitor in real-time:

```bash
./manage_autoapprove.sh logs
```

## Security Considerations

- The GitHub CLI must be authenticated with a personal access token
- The install script will prompt for authentication if `gh auth status` fails
- The script runs under your user account and never stores tokens in plaintext
- Only PRs with configured labels are considered for approval

This is intended for internal use by Customer Success Engineers and assumes familiarity with GitHub CLI and macOS terminal usage
