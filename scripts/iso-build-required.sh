#!/usr/bin/env bash
set -Eeuo pipefail

saw_path=false
build_required=false

while IFS= read -r -d '' path; do
  saw_path=true

  case "$path" in
    .github/ISSUE_TEMPLATE/* \
    |.github/PULL_REQUEST_TEMPLATE.md \
    |.github/dependabot.yml \
    |.github/repository-metadata.json \
    |.github/workflows/delete-merged-branches.yml \
    |.github/workflows/release-gate.yml \
    |.github/workflows/validate.yml \
    |CHANGELOG.md \
    |CODE_OF_CONDUCT.md \
    |CONTRIBUTING.md \
    |LICENSE \
    |README.md \
    |SECURITY.md \
    |config/repository-protection.json \
    |docs/*)
      ;;
    *)
      build_required=true
      break
      ;;
  esac
done

# Empty or malformed comparisons fail safe to a complete image build.
if [[ "$saw_path" != true ]]; then
  build_required=true
fi

printf '%s\n' "$build_required"
