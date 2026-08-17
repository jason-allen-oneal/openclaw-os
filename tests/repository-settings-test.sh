#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT_DIR/config/repository-protection.json"
APPLY_SCRIPT="$ROOT_DIR/scripts/apply-repository-settings.sh"

jq -e '
  .schemaVersion == 1
  and .repository == "jason-allen-oneal/openclaw-os"
  and .defaultBranch == "main"
  and .deleteBranchOnMerge == true
  and .allowUpdateBranch == true
  and .main.strictStatusChecks == true
  and .main.enforceAdmins == true
  and .main.requiredApprovingReviewCount == 0
  and .main.requiredConversationResolution == true
  and .main.allowForcePushes == false
  and .main.allowDeletions == false
  and (.main.requiredStatusChecks | sort == ["build-amd64", "validate"])
' "$POLICY" >/dev/null

grep -Fq 'scripts/sync-repository-metadata.sh' "$APPLY_SCRIPT"
grep -Fq 'branches/$default_branch/protection' "$APPLY_SCRIPT"
grep -Fq 'requiredStatusChecks' "$APPLY_SCRIPT"
grep -Fq 'delete_branch_on_merge' "$APPLY_SCRIPT"
grep -Fq 'allow_update_branch' "$APPLY_SCRIPT"

echo "Repository settings tests passed."
