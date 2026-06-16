#!/usr/bin/env bash
# Comprehensive scenario tests for Grafana RBAC Terraform config
# Tests validation logic, edge cases, and robustness of the setup.
#
# Usage: bash test_scenarios.sh
# Requires: TF_VAR_grafana_url and TF_VAR_grafana_token env vars

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
CONFIG_DIR="$REPO_ROOT/config"
TERRAFORM="terraform"
PASS=0
FAIL=0
ERRORS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

backup_configs() {
  for f in roles.yaml folders.yaml teams.yaml; do
    cp "$CONFIG_DIR/$f" "$CONFIG_DIR/$f.bak"
  done
}

restore_configs() {
  for f in roles.yaml folders.yaml teams.yaml; do
    if [ -f "$CONFIG_DIR/$f.bak" ]; then
      mv "$CONFIG_DIR/$f.bak" "$CONFIG_DIR/$f"
    fi
  done
}

# Run terraform plan and capture exit code + output
run_plan() {
  cd "$TF_DIR"
  $TERRAFORM plan -no-color 2>&1 || true
}

run_validate() {
  cd "$TF_DIR"
  $TERRAFORM validate -no-color 2>&1 || true
}

# Run plan and check if it succeeded (exit 0) or had an error
plan_should_succeed() {
  local test_name="$1"
  echo ""
  echo "━━━ TEST: $test_name ━━━"
  cd "$TF_DIR"
  set +e
  local output
  output=$($TERRAFORM plan -no-color 2>&1)
  local exit_code=$?
  set -e
  if [ $exit_code -eq 0 ]; then
    # Check for precondition errors in output (terraform plan can exit 0 but have warnings)
    if echo "$output" | grep -q "Error:"; then
      echo "  ✗ FAIL — plan output contains errors"
      echo "$output" | grep -A2 "Error:" | head -10
      FAIL=$((FAIL+1))
      ERRORS+=("$test_name: plan contained errors")
    else
      echo "  ✓ PASS"
      PASS=$((PASS+1))
    fi
  else
    # Check if the failure is ONLY from the expected precondition
    if echo "$output" | grep -q "Error:"; then
      echo "  ✗ FAIL — plan failed with errors:"
      echo "$output" | grep -A2 "Error:" | head -10
      FAIL=$((FAIL+1))
      ERRORS+=("$test_name: plan failed unexpectedly")
    else
      echo "  ✗ FAIL — plan failed with exit code $exit_code"
      FAIL=$((FAIL+1))
      ERRORS+=("$test_name: exit code $exit_code")
    fi
  fi
}

plan_should_fail_with() {
  local test_name="$1"
  local expected_error="$2"
  echo ""
  echo "━━━ TEST: $test_name ━━━"
  cd "$TF_DIR"
  local output
  output=$($TERRAFORM plan -no-color 2>&1) || true
  if echo "$output" | grep -qi "$expected_error"; then
    echo "  ✓ PASS — correctly rejected with: $expected_error"
    PASS=$((PASS+1))
  else
    echo "  ✗ FAIL — expected error containing '$expected_error' but got:"
    echo "$output" | grep -A2 "Error:" | head -10
    FAIL=$((FAIL+1))
    ERRORS+=("$test_name: missing expected error '$expected_error'")
  fi
}

validate_should_fail() {
  local test_name="$1"
  echo ""
  echo "━━━ TEST: $test_name ━━━"
  cd "$TF_DIR"
  local output
  output=$($TERRAFORM validate -no-color 2>&1) || true
  if echo "$output" | grep -qi "error"; then
    echo "  ✓ PASS — validate correctly rejected config"
    PASS=$((PASS+1))
  else
    echo "  ✗ FAIL — validate should have rejected config"
    FAIL=$((FAIL+1))
    ERRORS+=("$test_name: validate did not reject")
  fi
}

trap restore_configs EXIT

echo "╔══════════════════════════════════════════════════════════╗"
echo "║   Grafana RBAC Terraform — Scenario Test Suite          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── SCENARIO 1: Baseline — current config should plan successfully ────────
backup_configs
plan_should_succeed "Baseline: current config plans successfully"
restore_configs

# ── SCENARIO 2: Add minimal team (only required fields) ──────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Minimal Team:
    email: minimal-test@company.com
EOF
plan_should_succeed "Minimal team: email only"
restore_configs

# ── SCENARIO 3: Add team with new folder (folder exists in folders.yaml) ──
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

test-new-folder:
  parent_key: osttra
  description: Test new folder
EOF
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test New Folder Team:
    email: folder-test@company.com
    folder: test-new-folder
    lbac:
      - '{ business_unit="test" }'
EOF
plan_should_succeed "New team with new folder"
restore_configs

# ── SCENARIO 4: Add team referencing non-existent folder ────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Bad Folder Team:
    email: badfolder@company.com
    folder: this-folder-does-not-exist
EOF
plan_should_fail_with "Team with non-existent owner folder" "undefined folders"
restore_configs

# ── SCENARIO 5: Add team referencing non-existent role ──────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Bad Role Team:
    email: badrole@company.com
    roles:
      - this_role_does_not_exist
EOF
plan_should_fail_with "Team with non-existent extra role" "undefined roles"
restore_configs

# ── SCENARIO 8: Add team with invalid folder permission level ────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

shared:
  parent_key: osttra
  description: Shared folder
EOF
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Bad Perm Team:
    email: badperm@company.com
    folder_permissions:
      shared: ReadWrite
EOF
plan_should_fail_with "Team with invalid permission level" "invalid folder permission"
restore_configs

# ── SCENARIO 9: Team with LBAC selectors but no datasources ──────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test LBAC No DS Team:
    email: lbac-nods@company.com
    datasources: []
    lbac:
      - '{ bu="test" }'
EOF
plan_should_fail_with "Team with LBAC but empty datasources" "lbac_selectors but no datasources"
restore_configs

# ── SCENARIO 10: Add only a folder (no team uses it) ────────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

standalone-test-folder:
  parent_key: osttra
  description: Standalone test folder
EOF
plan_should_succeed "Standalone folder (no team using it)"
restore_configs

# ── SCENARIO 11: Team with extra folder_permissions on existing folder ────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

infrastructure:
  parent_key: osttra
  description: Infrastructure folder

executive:
  parent_key: osttra
  description: Executive folder

availability:
  parent_key: osttra
  description: Availability folder
EOF
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Extra Perms Team:
    email: extraperms@company.com
    folder_permissions:
      infrastructure: View
      executive: View
      availability: View
EOF
plan_should_succeed "Team with extra folder permissions"
restore_configs

# ── SCENARIO 12: Team with group_uid for AD sync ────────────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test AD Sync Team:
    email: adsync@company.com
    group_uid: 12345678-1234-1234-1234-123456789012
    lbac:
      - '{ bu="test" }'
EOF
plan_should_succeed "Team with AD sync group_uid"
restore_configs

# ── SCENARIO 13: Two teams sharing same owner folder ────────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

trioptima:
  parent_key: osttra
  description: TriOptima folder
EOF
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Shared Folder A:
    email: shared-a@company.com
    folder: trioptima
    lbac:
      - '{ bu="test-a" }'

  Test Shared Folder B:
    email: shared-b@company.com
    folder: trioptima
    lbac:
      - '{ bu="test-b" }'
EOF
plan_should_succeed "Two teams sharing same owner folder"
restore_configs

# ── SCENARIO 16: Folder with slash in name ────────────────────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

bad/folder:
  parent_key: osttra
  description: Folder with slash
EOF
plan_should_fail_with "Folder with slash in name" "must not contain"
restore_configs

# ── SCENARIO 17: Over-nested folder (3 levels) ───────────────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

sre:
  description: SRE root folder

child-folder:
  parent_key: sre
  description: Child folder

grandchild-folder:
  parent_key: child-folder
  description: Grandchild folder (should fail — 3rd level)
EOF
plan_should_fail_with "Over-nested folder (3 levels)" "3rd level"
restore_configs

# ── SCENARIO 18: Team with all optional fields populated ─────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

full-test-folder:
  parent_key: osttra
  description: Full test folder

shared:
  parent_key: osttra
  description: Shared folder

executive:
  parent_key: osttra
  description: Executive folder
EOF
cat >> "$CONFIG_DIR/roles.yaml" << 'EOF'

governance_reader:
  description: Governance reader role
  permissions:
    fixed:roles:reader: ""
EOF
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Full Featured Team:
    email: full-featured@company.com
    folder: full-test-folder
    group_uid: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    roles:
      - governance_reader
    folder_permissions:
      shared: Edit
      executive: View
    lbac:
      - '{ business_unit="full-test" }'
EOF
plan_should_succeed "Fully-featured team with all optional fields"
restore_configs

# ── SCENARIO 19: Minimal team gets default LBAC selector ─────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  Test Default LBAC Team:
    email: default-lbac@company.com
EOF
plan_should_succeed "Minimal team inherits default LBAC selector"
restore_configs

# ── SCENARIO 20: Folder referencing undefined parent key ─────────────────
backup_configs
cat >> "$CONFIG_DIR/folders.yaml" << 'EOF'

bad-parent-folder:
  parent_key: non-existent-parent
  description: Folder with undefined parent key
EOF
plan_should_fail_with "Folder referencing undefined parent key" "undefined parent keys"
restore_configs

# ── SCENARIO 21: Team name too long (> 255 chars) ────────────────────────
backup_configs
cat >> "$CONFIG_DIR/teams.yaml" << 'EOF'

  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:
    email: toolong@company.com
EOF
plan_should_fail_with "Team name too long (> 255 chars)" "exceed Grafana's 255-character limit"
restore_configs

# ── RESULTS ──────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   RESULTS                                               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║   Passed: $PASS                                          "
echo "║   Failed: $FAIL                                          "
echo "╚══════════════════════════════════════════════════════════╝"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "FAILURES:"
  for err in "${ERRORS[@]}"; do
    echo "  • $err"
  done
  exit 1
fi

echo ""
echo "All scenarios passed! ✅"
