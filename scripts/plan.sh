#!/usr/bin/env bash
# Plan a Terragrunt stack against a local copy of state.
#
# Why not just `terragrunt plan`?
# Running plan against remote state acquires a lock for the full duration.
# Under concurrent PRs (or matrix CI jobs), this causes lock contention and
# flaky pipelines. This script pulls the state once, then plans against the
# local copy — no lock held, no side effects, identical to what CI runs.
#
# Usage:
#   ./scripts/plan.sh live/production/cluster/eks
#   ./scripts/plan.sh live/production/account/vpc
#
# Prerequisites:
#   - Valid AWS session (aws sts get-caller-identity must succeed)
#   - DOMAIN_NAME, TF_VAR_ADMIN_CIDR, REPO_URL set (or in .env)
#   - terragrunt and terraform installed (pin versions with tfenv/tgenv)
#
# Environment:
#   PLAN_OUT  — path to write the binary plan file (default: /tmp/tg-plan.out)
#   STATE_OUT — path to write the pulled state   (default: /tmp/tg-plan-state.tfstate)

set -euo pipefail

STACK="${1:?Usage: $0 <stack-path>  e.g. live/production/cluster/eks}"
PLAN_OUT="${PLAN_OUT:-/tmp/tg-plan.out}"
STATE_OUT="${STATE_OUT:-/tmp/tg-plan-state.tfstate}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source .env if it exists at repo root (contains DOMAIN_NAME, TF_VAR_ADMIN_CIDR, REPO_URL)
if [[ -f "$REPO_ROOT/.env" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.env"
fi

STACK_PATH="$REPO_ROOT/$STACK"

if [[ ! -d "$STACK_PATH" ]]; then
  echo "ERROR: Stack directory not found: $STACK_PATH" >&2
  exit 1
fi

echo "Stack:  $STACK"
echo "State:  $STATE_OUT"
echo "Plan:   $PLAN_OUT"
echo ""

cd "$STACK_PATH"

echo "→ Pulling current state (read-only, no lock acquired for plan)..."
terragrunt state pull > "$STATE_OUT"

STATE_RESOURCES=$(python3 -c "
import json, sys
s = json.load(open('$STATE_OUT'))
print(len(s.get('resources', [])))
" 2>/dev/null || echo "?")
echo "  State contains $STATE_RESOURCES resource(s)"
echo ""

echo "→ Planning against local state copy..."
terragrunt plan \
  -state="$STATE_OUT" \
  -lock=false \
  -out="$PLAN_OUT"

echo ""
echo "✓ Plan complete. To review:"
echo "  terragrunt show $PLAN_OUT"
echo ""
echo "To apply (acquires real lock, writes to remote state):"
echo "  cd $STACK_PATH && terragrunt apply"
