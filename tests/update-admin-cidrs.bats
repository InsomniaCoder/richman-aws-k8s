#!/usr/bin/env bats
# Tests for scripts/update-admin-cidrs.sh
#
# Run locally:
#   brew install bats-core   # or: apt-get install bats
#   bats tests/update-admin-cidrs.bats
#
# These tests exercise the script's core logic without real network calls.
# Network calls are intercepted by overriding curl in the test environment.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/update-admin-cidrs.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

setup() {
  # Create a temp directory with a valid admin-cidrs.json for each test
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/live/production"
  cat > "$TEST_DIR/live/production/admin-cidrs.json" <<'EOF'
{
  "_comment": "test fixture",
  "cidrs": ["10.0.0.1/32"]
}
EOF
  export TEST_DIR

  # Override curl so tests don't make real network calls.
  # Individual tests can override these stubs for specific scenarios.
  export MOCK_MY_IP="1.2.3.4"
  export MOCK_GITHUB_RESPONSE='{"actions":["192.0.2.0/24","198.51.100.0/24"]}'
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Stub curl: returns MOCK_MY_IP for checkip and MOCK_GITHUB_RESPONSE for api.github.com
_stub_curl() {
  # Write a curl wrapper to a temp bin dir on PATH
  local bin_dir="$TEST_DIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'STUB'
#!/usr/bin/env bash
url="${@: -1}"
if [[ "$url" == *"checkip"* ]]; then
  echo "$MOCK_MY_IP"
elif [[ "$url" == *"api.github.com"* ]]; then
  echo "$MOCK_GITHUB_RESPONSE"
fi
STUB
  chmod +x "$bin_dir/curl"
  export PATH="$bin_dir:$PATH"
}

_cidrs_file() {
  echo "$TEST_DIR/live/production/admin-cidrs.json"
}

_run_script() {
  run bash "$SCRIPT" --env "live/production" "$@"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

@test "no change when file already matches" {
  # Write exact expected content first
  cat > "$(_cidrs_file)" <<'EOF'
{"cidrs":["1.2.3.4/32","192.0.2.0/24","198.51.100.0/24"]}
EOF
  # Normalise: the script sorts and deduplicates, so pre-sort the file too
  # (jq writes sorted array)
  jq '.cidrs |= sort' "$(_cidrs_file)" > "$(_cidrs_file).tmp" && mv "$(_cidrs_file).tmp" "$(_cidrs_file)"

  _stub_curl
  cd "$TEST_DIR"
  _run_script --no-my-ip  # simplify by disabling my-ip; only github CIDRs
  # With no-my-ip: only github CIDRs from mock: 192.0.2.0/24 and 198.51.100.0/24
  # Pre-write that exact state
  cat > "$(_cidrs_file)" <<'EOF'
{"cidrs":["192.0.2.0/24","198.51.100.0/24"]}
EOF
  _run_script --no-my-ip
  [[ "$output" == *"No change"* ]]
}

@test "updates file when CIDRs change" {
  cat > "$(_cidrs_file)" <<'EOF'
{"_comment":"test","cidrs":["10.0.0.1/32"]}
EOF
  _stub_curl
  cd "$TEST_DIR"
  _run_script --no-my-ip  # only github mock: 192.0.2.0/24, 198.51.100.0/24
  [ "$status" -eq 0 ]
  new_cidrs="$(jq -r '.cidrs[]' "$(_cidrs_file)")"
  [[ "$new_cidrs" == *"192.0.2.0/24"* ]]
  [[ "$new_cidrs" == *"198.51.100.0/24"* ]]
  # Old CIDR should be gone (it wasn't in any source)
  [[ "$new_cidrs" != *"10.0.0.1/32"* ]]
}

@test "my_ip is included as /32" {
  cat > "$(_cidrs_file)" <<'EOF'
{"cidrs":[]}
EOF
  _stub_curl
  cd "$TEST_DIR"
  _run_script --no-github
  [ "$status" -eq 0 ]
  new_cidrs="$(jq -r '.cidrs[]' "$(_cidrs_file)")"
  [[ "$new_cidrs" == *"1.2.3.4/32"* ]]
}

@test "dry-run does not write file" {
  original="$(cat "$(_cidrs_file)")"
  _stub_curl
  cd "$TEST_DIR"
  _run_script --dry-run --no-my-ip
  [ "$status" -eq 0 ]
  [[ "$(cat "$(_cidrs_file)")" == "$original" ]]
  [[ "$output" == *"dry-run"* ]]
}

@test "fails when cidrs file missing" {
  rm "$(_cidrs_file)"
  cd "$TEST_DIR"
  run bash "$SCRIPT" --env live/production --no-my-ip --no-github
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "fails when no CIDRs collected from any source" {
  export MOCK_MY_IP=""
  export MOCK_GITHUB_RESPONSE='{"actions":[]}'
  _stub_curl
  cd "$TEST_DIR"
  _run_script --no-github  # no-github disables github source; my-ip returns empty
  # With empty my-ip and no static CIDRs this should fail
  # Note: --no-github + empty my-ip + no static = zero CIDRs
  [ "$status" -ne 0 ]
}

@test "deduplicates CIDRs from multiple sources" {
  # GitHub returns 192.0.2.0/24 and my-ip also returns something that
  # duplicates one of the github CIDRs
  export MOCK_MY_IP="192.0.2.5"   # /32 — different from the /24 but not a dup
  export MOCK_GITHUB_RESPONSE='{"actions":["192.0.2.0/24","192.0.2.0/24"]}'
  _stub_curl
  cat > "$(_cidrs_file)" <<'EOF'
{"cidrs":[]}
EOF
  cd "$TEST_DIR"
  _run_script
  [ "$status" -eq 0 ]
  count="$(jq '.cidrs | length' "$(_cidrs_file)")"
  # 192.0.2.0/24 (deduplicated to 1) + 192.0.2.5/32 = 2
  [ "$count" -eq 2 ]
}

@test "IPv6 CIDRs are excluded from github ranges" {
  export MOCK_GITHUB_RESPONSE='{"actions":["192.0.2.0/24","2001:db8::/32","198.51.100.0/24"]}'
  export MOCK_MY_IP=""
  _stub_curl
  cat > "$(_cidrs_file)" <<'EOF'
{"cidrs":[]}
EOF
  cd "$TEST_DIR"
  _run_script --no-my-ip
  [ "$status" -eq 0 ]
  cidrs="$(jq -r '.cidrs[]' "$(_cidrs_file)")"
  [[ "$cidrs" != *"2001:db8"* ]]
  [[ "$cidrs" == *"192.0.2.0/24"* ]]
}
