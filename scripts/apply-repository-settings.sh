#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_FILE="$ROOT_DIR/.github/repository-metadata.json"
PROTECTION_FILE="$ROOT_DIR/config/repository-protection.json"
API_VERSION="2022-11-28"

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required." >&2
  exit 1
}

for file in "$METADATA_FILE" "$PROTECTION_FILE"; do
  [[ -f "$file" && ! -L "$file" ]] || {
    echo "Repository settings file is missing or unsafe: $file" >&2
    exit 1
  }
done

gh auth status >/dev/null

repository="$(jq -er '.repository' "$PROTECTION_FILE")"
metadata_repository="$(jq -er '.repository' "$METADATA_FILE")"
default_branch="$(jq -er '.defaultBranch' "$PROTECTION_FILE")"
[[ "$repository" == "$metadata_repository" ]] || {
  echo "Repository metadata and protection policy target different repositories." >&2
  exit 1
}

current_repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
[[ "$current_repository" == "$repository" ]] || {
  printf 'Refusing to update %s from policy for %s.\n' \
    "$current_repository" "$repository" >&2
  exit 1
}

admin="$(gh api \
  -H "X-GitHub-Api-Version: $API_VERSION" \
  "repos/$repository" \
  --jq '.permissions.admin // false')"
[[ "$admin" == "true" ]] || {
  echo "The authenticated account is not a repository administrator." >&2
  exit 1
}

"$ROOT_DIR/scripts/sync-repository-metadata.sh"

delete_branch_on_merge="$(jq -er '.deleteBranchOnMerge' "$PROTECTION_FILE")"
allow_update_branch="$(jq -er '.allowUpdateBranch' "$PROTECTION_FILE")"

gh api \
  --method PATCH \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: $API_VERSION" \
  "repos/$repository" \
  -F "delete_branch_on_merge=$delete_branch_on_merge" \
  -F "allow_update_branch=$allow_update_branch" \
  >/dev/null

protection_payload="$(
  jq '{
    required_status_checks: {
      strict: .main.strictStatusChecks,
      checks: (.main.requiredStatusChecks | map({context: .}))
    },
    enforce_admins: .main.enforceAdmins,
    required_pull_request_reviews: {
      dismiss_stale_reviews: false,
      require_code_owner_reviews: false,
      required_approving_review_count: .main.requiredApprovingReviewCount,
      require_last_push_approval: false
    },
    restrictions: null,
    required_linear_history: false,
    allow_force_pushes: .main.allowForcePushes,
    allow_deletions: .main.allowDeletions,
    block_creations: false,
    required_conversation_resolution: .main.requiredConversationResolution,
    lock_branch: false,
    allow_fork_syncing: false
  }' "$PROTECTION_FILE"
)"

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: $API_VERSION" \
  "repos/$repository/branches/$default_branch/protection" \
  --input - \
  <<<"$protection_payload" \
  >/dev/null

expected_checks="$(
  jq -c '.main.requiredStatusChecks | sort' "$PROTECTION_FILE"
)"
protection_state="$(
  gh api \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repository/branches/$default_branch/protection"
)"
actual_checks="$(
  jq -c '[.required_status_checks.checks[].context] | sort' \
    <<<"$protection_state"
)"
[[ "$actual_checks" == "$expected_checks" ]] || {
  printf 'Required checks mismatch. Expected %s, got %s.\n' \
    "$expected_checks" "$actual_checks" >&2
  exit 1
}

jq -e \
  --argjson policy "$(cat "$PROTECTION_FILE")" \
  '
    .required_status_checks.strict == $policy.main.strictStatusChecks
    and .enforce_admins.enabled == $policy.main.enforceAdmins
    and .required_pull_request_reviews.required_approving_review_count
      == $policy.main.requiredApprovingReviewCount
    and .required_conversation_resolution.enabled
      == $policy.main.requiredConversationResolution
    and .allow_force_pushes.enabled == $policy.main.allowForcePushes
    and .allow_deletions.enabled == $policy.main.allowDeletions
  ' \
  <<<"$protection_state" >/dev/null || {
    echo "Live branch protection does not match the canonical policy." >&2
    exit 1
  }

repo_state="$(
  gh api \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repository"
)"
[[ "$(jq -r '.delete_branch_on_merge' <<<"$repo_state")" == "$delete_branch_on_merge" ]]
[[ "$(jq -r '.allow_update_branch' <<<"$repo_state")" == "$allow_update_branch" ]]

echo "Repository settings applied and verified for $repository."
echo "Required checks: $(jq -r '.main.requiredStatusChecks | join(", ")' "$PROTECTION_FILE")"
