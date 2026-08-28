#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 12 ]]; then
  echo "usage: $0 DIST TAG COMMIT BUILD_RUN_JSON VALIDATE_RUN_JSON ARTIFACT_JSON ISSUES_JSON APPROVAL_JSON NOTES_JSON REPOSITORY GENERATED_AT WORKFLOW_RUN_URL" >&2
  exit 2
fi

DIST_DIR="$1"
TAG="$2"
SOURCE_COMMIT="$3"
BUILD_RUN_JSON="$4"
VALIDATE_RUN_JSON="$5"
ARTIFACT_JSON="$6"
ISSUES_JSON="$7"
APPROVAL_JSON="$8"
NOTES_JSON="$9"
REPOSITORY="${10}"
GENERATED_AT="${11}"
WORKFLOW_RUN_URL="${12}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(<"$ROOT_DIR/VERSION")"
PREFIX="openclaw-os-${VERSION}-amd64"

fail() {
  echo "release evidence: $*" >&2
  exit 1
}

[[ "$TAG" == "v$VERSION" ]] || fail "tag does not match VERSION"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]] \
  || fail "VERSION is not an alpha prerelease"
[[ "$SOURCE_COMMIT" =~ ^[a-f0-9]{40}$ ]] || fail "source commit is invalid"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository is invalid"
[[ "$WORKFLOW_RUN_URL" =~ ^https://github.com/[^/]+/[^/]+/actions/runs/[0-9]+$ ]] \
  || fail "publication workflow URL is invalid"

iso="$DIST_DIR/${PREFIX}.iso"
iso_checksum="$iso.sha256"
sbom="$DIST_DIR/${PREFIX}.sbom.spdx.json"
sbom_checksum="$sbom.sha256"
build_manifest="$DIST_DIR/${PREFIX}.build.json"
installed_evidence="$DIST_DIR/${PREFIX}.installed-system-evidence.build.json"
installed_checksum="$DIST_DIR/${PREFIX}.installed-system-checksum.build.json"

for file in "$iso" "$iso_checksum" "$sbom" "$sbom_checksum" \
  "$build_manifest" "$installed_evidence" "$installed_checksum" "$BUILD_RUN_JSON" \
  "$VALIDATE_RUN_JSON" "$ARTIFACT_JSON" "$ISSUES_JSON" "$APPROVAL_JSON" \
  "$NOTES_JSON"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe file: $file"
done

(cd "$DIST_DIR" && sha256sum --check --strict "$(basename "$iso_checksum")")
(cd "$DIST_DIR" && sha256sum --check --strict "$(basename "$sbom_checksum")")

iso_digest="$(sha256sum "$iso" | awk '{print $1}')"
build_digest="$(sha256sum "$build_manifest" | awk '{print $1}')"
build_run_digest="$(sha256sum "$BUILD_RUN_JSON" | awk '{print $1}')"
checksum_digest="$(sha256sum "$iso_checksum" | awk '{print $1}')"
sbom_digest="$(sha256sum "$sbom" | awk '{print $1}')"
installed_digest="$(sha256sum "$installed_evidence" | awk '{print $1}')"
notes_digest="$(sha256sum "$NOTES_JSON" | awk '{print $1}')"
built_at="$(jq -er '.updatedAt' "$BUILD_RUN_JSON")"
install -m 0644 "$NOTES_JSON" "$DIST_DIR/${PREFIX}.release-notes.json"
install -m 0644 "$BUILD_RUN_JSON" "$DIST_DIR/${PREFIX}.build-run.json"

jq -e --arg version "$VERSION" --arg commit "$SOURCE_COMMIT" '
  .openclawOsVersion == $version and .gitCommit == $commit
' "$build_manifest" >/dev/null || fail "build manifest identity mismatch"
jq -e '
  .spdxVersion == "SPDX-2.3"
  and ([.packages[] | select(.SPDXID | startswith("SPDXRef-NpmPackage-"))] | length > 0)
' "$sbom" >/dev/null || fail "SBOM lacks the OpenClaw npm dependency inventory"
jq -e --arg commit "$SOURCE_COMMIT" --arg iso_digest "$iso_digest" '
  .commit == $commit
  and .result == "passed"
  and .sourceIso.sha256 == $iso_digest
  and ([.cases[] | select(.id == "uefi" and .firmware == "uefi" and .machine == "q35" and .status == "passed")] | length == 1)
  and ([.cases[] | select(.id == "bios" and .firmware == "bios" and .machine == "pc" and .status == "passed")] | length == 1)
  and ([.cases[] | select(
    .upgrade.result == "passed"
    and .upgrade.sequence == ["activate-previous", "upgrade-candidate", "rollback-previous", "reapply-candidate"]
  )] | length >= 1)
' "$installed_evidence" >/dev/null || fail "installed-system evidence is incomplete"
jq -e --arg file "$(basename "$installed_evidence")" --arg digest "$installed_digest" '
  .algorithm == "sha256" and .file == $file and .sha256 == $digest
' "$installed_checksum" >/dev/null || fail "installed-system evidence checksum mismatch"

for run_file in "$BUILD_RUN_JSON" "$VALIDATE_RUN_JSON"; do
  jq -e --arg commit "$SOURCE_COMMIT" --arg repo "$REPOSITORY" '
    .conclusion == "success"
    and .headSha == $commit
    and .event == "push"
    and .headBranch == "main"
    and .runAttempt >= 1
    and .repository == $repo
    and (.url | test("^https://github\\.com/.+/.+/actions/runs/[0-9]+$"))
  ' "$run_file" >/dev/null || fail "workflow run is not a successful main build of the source commit"
done
jq -e '
  .workflowName == "Build ISO"
  and .workflowPath == ".github/workflows/build-iso.yml"
' "$BUILD_RUN_JSON" >/dev/null \
  || fail "build run is not the Build ISO workflow"
jq -e '
  .workflowName == "Validate"
  and .workflowPath == ".github/workflows/validate.yml"
' "$VALIDATE_RUN_JSON" >/dev/null \
  || fail "validate run is not the Validate workflow"
jq -e '
  [.jobs[]
    | select(.name == "build-amd64" and .conclusion == "success")
    | .steps[]
    | select(.name == "UEFI live-boot smoke test" and .conclusion == "success")]
  | length == 1
' "$BUILD_RUN_JSON" >/dev/null || fail "build run lacks successful live/install smoke evidence"

jq -e --arg commit "$SOURCE_COMMIT" '
  .name == "openclaw-os-amd64"
  and .expired == false
  and .sizeInBytes > 0
  and (.id | type == "number")
  and (.archiveDigest | test("^sha256:[a-f0-9]{64}$"))
  and .workflowRunHeadSha == $commit
' "$ARTIFACT_JSON" >/dev/null || fail "Actions artifact identity is invalid"

manifest_built_at="$(jq -er '.builtAt' "$build_manifest")"
run_created_at="$(jq -er '.createdAt' "$BUILD_RUN_JSON")"
python3 - "$run_created_at" "$manifest_built_at" "$built_at" <<'PY'
from datetime import datetime
import sys
parse = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
created, built, completed = map(parse, sys.argv[1:])
if not created <= built <= completed:
    raise SystemExit("build manifest timestamp is outside the immutable workflow run")
PY

build_url="$(jq -er '.url' "$BUILD_RUN_JSON")"
validate_url="$(jq -er '.url' "$VALIDATE_RUN_JSON")"

jq -e '
  type == "array"
  and length > 0
  and all(.[]; (.number | type == "number") and (.state == "open" or .state == "closed") and (.url | type == "string"))
' "$ISSUES_JSON" >/dev/null || fail "issue snapshot is invalid"
jq -e --arg run_url "$WORKFLOW_RUN_URL" '
  .role == "release-owner"
  and .method == "protected-environment"
  and .environment == "alpha-release"
  and .runUrl == $run_url
  and (.login | type == "string" and length > 0)
  and (.observedAt | type == "string" and length > 0)
  and .timestampSource == "protected-job-start"
  and (.jobId | type == "number" and . > 0)
  and .runAttempt == 1
' "$APPROVAL_JSON" >/dev/null || fail "protected release approval is invalid"

jq -n \
  --arg generated_at "$GENERATED_AT" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg artifact_name "$(basename "$iso")" \
  --arg artifact_digest "$iso_digest" \
  --arg built_at "$built_at" \
  --arg build_url "$build_url" \
  --arg validate_url "$validate_url" \
  --arg build_digest "$build_digest" \
  --arg build_run_digest "$build_run_digest" \
  --arg checksum_digest "$checksum_digest" \
  --arg sbom_digest "$sbom_digest" \
  --arg installed_digest "$installed_digest" \
  --arg notes_digest "$notes_digest" \
  --arg workflow_run_url "$WORKFLOW_RUN_URL" \
  --arg release_url "https://github.com/${REPOSITORY}/releases/tag/${TAG}" \
  --slurpfile actions_artifact "$ARTIFACT_JSON" \
  --slurpfile issues "$ISSUES_JSON" \
  --slurpfile approval "$APPROVAL_JSON" \
  --slurpfile notes "$NOTES_JSON" \
  '{
    schemaVersion: 1,
    channel: "alpha",
    sourceCommit: $source_commit,
    generatedAt: $generated_at,
    artifact: {
      name: $artifact_name,
      digestAlgorithm: "sha256",
      testedDigest: $artifact_digest,
      promotedDigest: $artifact_digest,
      sourceCommit: $source_commit,
      builtAt: $built_at,
      actionsArtifact: $actions_artifact[0]
    },
    checks: {
      validate: {status: "success", headSha: $source_commit, runUrl: $validate_url},
      "build-amd64": {status: "success", headSha: $source_commit, runUrl: $build_url}
    },
    evidence: [
      {name: "artifact-manifest", url: ($release_url + "#artifact-manifest"), sha256: $build_digest},
      {name: "checksums", url: ($release_url + "#checksums"), sha256: $checksum_digest},
      {name: "sbom", url: ($release_url + "#sbom"), sha256: $sbom_digest},
      {name: "uefi-live-boot", url: ($release_url + "#uefi-live-boot"), sha256: $build_run_digest},
      {name: "clean-install", url: ($release_url + "#clean-install"), sha256: $installed_digest},
      {name: "update-code-rollback", url: ($release_url + "#update-code-rollback"), sha256: $installed_digest},
      {name: "known-limitations", url: ($release_url + "#known-limitations"), sha256: $notes_digest}
    ],
    issues: $issues[0],
    approvals: [$approval[0]],
    waivers: [],
    releaseNotes: $notes[0]
  }' >"$DIST_DIR/${PREFIX}.release-evidence.json"

node "$ROOT_DIR/scripts/release-gate.mjs" evidence \
  "$ROOT_DIR/config/release-promotion-policy.json" \
  "$DIST_DIR/${PREFIX}.release-evidence.json"

printf 'Prepared release evidence: %s\n' "$DIST_DIR/${PREFIX}.release-evidence.json"
