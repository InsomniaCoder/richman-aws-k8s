#!/usr/bin/env bash
# Fetch allowed CIDRs for the EKS API server whitelist and update admin-cidrs.json.
#
# Sources (all are fetched and merged):
#   1. STATIC_CIDRS  — hardcoded VPN / office / bastion CIDRs (edit below)
#   2. MY_IP         — the machine running this script (useful for dev laptops)
#   3. GITHUB_CIDRS  — GitHub Actions egress IPs (so CI can reach the API server)
#
# Behaviour:
#   - If the resulting CIDR list matches what's already in admin-cidrs.json: exit 0, no change.
#   - If something changed: update admin-cidrs.json and exit 0.
#     In CI the calling workflow detects the file change and opens a PR.
#     Locally you see a diff and can commit manually.
#
# Usage:
#   ./scripts/update-admin-cidrs.sh [--env live/production]
#
# Options:
#   --env PATH   Path to the environment directory containing admin-cidrs.json
#                (default: live/production)
#   --no-my-ip   Skip fetching the current machine's public IP
#   --no-github  Skip fetching GitHub Actions IP ranges
#
# Prerequisites:
#   - curl, jq (both standard on macOS and GitHub Actions ubuntu-latest)
#
# Testing:
#   Run with --dry-run to print the computed list without writing anything.
#   Run with BATS (tests/update-admin-cidrs.bats) for unit tests.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$REPO_ROOT/live/production"
INCLUDE_MY_IP=true
INCLUDE_GITHUB=true
DRY_RUN=false

# ── Parse arguments ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)        ENV_DIR="$REPO_ROOT/$2"; shift 2 ;;
    --no-my-ip)   INCLUDE_MY_IP=false; shift ;;
    --no-github)  INCLUDE_GITHUB=false; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CIDRS_FILE="$ENV_DIR/admin-cidrs.json"

if [[ ! -f "$CIDRS_FILE" ]]; then
  echo "ERROR: $CIDRS_FILE not found" >&2
  exit 1
fi

# ── Source definitions ────────────────────────────────────────────────────────
# Edit STATIC_CIDRS to add your VPN gateway IPs, office egress CIDRs, or
# bastion host IPs. These are committed to Git and reviewed in PRs — treat
# them as policy, not secrets.

STATIC_CIDRS=(
  # "203.0.113.0/24"   # Example: HQ office NAT gateway
  # "198.51.100.5/32"  # Example: VPN endpoint
)

# ── Fetch sources ─────────────────────────────────────────────────────────────

collected=()

# 1. Static CIDRs
for cidr in "${STATIC_CIDRS[@]+"${STATIC_CIDRS[@]}"}"; do
  collected+=("$cidr")
done

# 2. Current machine's public IP
if [[ "$INCLUDE_MY_IP" == "true" ]]; then
  my_ip="$(curl -sf --max-time 5 https://checkip.amazonaws.com || true)"
  if [[ -n "$my_ip" ]]; then
    my_ip="$(echo "$my_ip" | tr -d '[:space:]')"
    collected+=("${my_ip}/32")
    echo "  my_ip:    ${my_ip}/32"
  else
    echo "  my_ip:    (fetch failed — skipped)"
  fi
fi

# 3. GitHub Actions egress IPs (hooks.cidr under actions key)
# Source: https://api.github.com/meta
# We take only the `actions` prefixes — these are the IPs that GitHub-hosted
# runners use for outbound connections, i.e. what calls `kubectl` in CI.
if [[ "$INCLUDE_GITHUB" == "true" ]]; then
  github_meta="$(curl -sf --max-time 10 https://api.github.com/meta || true)"
  if [[ -n "$github_meta" ]]; then
    mapfile -t github_cidrs < <(echo "$github_meta" | jq -r '.actions[]' 2>/dev/null | grep -v ':' || true)
    for cidr in "${github_cidrs[@]+"${github_cidrs[@]}"}"; do
      collected+=("$cidr")
    done
    echo "  github:   ${#github_cidrs[@]} IPv4 CIDRs from api.github.com/meta"
  else
    echo "  github:   (fetch failed — skipped)"
  fi
fi

# ── Deduplicate and sort ──────────────────────────────────────────────────────

if [[ ${#collected[@]} -eq 0 ]]; then
  echo "ERROR: No CIDRs collected from any source." >&2
  echo "       Add entries to STATIC_CIDRS in this script or ensure network access." >&2
  exit 1
fi

# Sort and deduplicate
mapfile -t new_cidrs < <(printf '%s\n' "${collected[@]}" | sort -u)

# AWS hard limit check
if [[ ${#new_cidrs[@]} -gt 40 ]]; then
  echo "ERROR: ${#new_cidrs[@]} CIDRs collected but AWS allows a maximum of 40." >&2
  echo "       Reduce STATIC_CIDRS or disable --github / --my-ip sources." >&2
  exit 1
fi

echo "  total:    ${#new_cidrs[@]} unique CIDRs"

# ── Compare to current file ───────────────────────────────────────────────────

current_cidrs="$(jq -r '.cidrs | sort | .[]' "$CIDRS_FILE" 2>/dev/null || echo "")"
new_cidrs_str="$(printf '%s\n' "${new_cidrs[@]}")"

if [[ "$current_cidrs" == "$new_cidrs_str" ]]; then
  echo "✓ No change — admin-cidrs.json is already up to date."
  exit 0
fi

echo ""
echo "Changes detected:"
diff <(echo "$current_cidrs") <(echo "$new_cidrs_str") || true
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "(dry-run — not writing changes)"
  exit 0
fi

# ── Write updated file ────────────────────────────────────────────────────────

# Build JSON array
cidrs_json="$(printf '%s\n' "${new_cidrs[@]}" | jq -R . | jq -s '.')"

jq --argjson cidrs "$cidrs_json" '.cidrs = $cidrs' "$CIDRS_FILE" > "${CIDRS_FILE}.tmp"
mv "${CIDRS_FILE}.tmp" "$CIDRS_FILE"

echo "✓ Updated $CIDRS_FILE with ${#new_cidrs[@]} CIDRs."
