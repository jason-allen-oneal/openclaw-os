#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(<"$ROOT_DIR/VERSION")"
PREFIX="openclaw-os-${VERSION}-amd64"
COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
dist="$scratch/dist"
mkdir -p "$dist"

printf 'test iso\n' >"$dist/${PREFIX}.iso"
(cd "$dist" && sha256sum "${PREFIX}.iso" >"${PREFIX}.iso.sha256")
jq -n '{
  spdxVersion: "SPDX-2.3",
  packages: [{SPDXID: "SPDXRef-NpmPackage-0", name: "dependency", versionInfo: "1.0.0"}]
}' >"$dist/${PREFIX}.sbom.spdx.json"
(cd "$dist" && sha256sum "${PREFIX}.sbom.spdx.json" >"${PREFIX}.sbom.spdx.json.sha256")

built_at="$(date --utc --date='25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
generated_at="$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg version "$VERSION" --arg commit "$COMMIT" --arg built_at "$built_at" '{
  openclawOsVersion: $version,
  gitCommit: $commit,
  builtAt: $built_at
}' >"$dist/${PREFIX}.build.json"
iso_digest="$(sha256sum "$dist/${PREFIX}.iso" | awk '{print $1}')"
jq -n --arg commit "$COMMIT" --arg iso_digest "$iso_digest" '{
  commit: $commit,
  result: "passed",
  sourceIso: {sha256: $iso_digest},
  cases: [
    {
      id: "uefi", firmware: "uefi", machine: "q35", status: "passed",
      upgrade: {
        result: "passed",
        sequence: ["activate-previous", "upgrade-candidate", "rollback-previous", "reapply-candidate"]
      }
    },
    {id: "bios", firmware: "bios", machine: "pc", status: "passed", upgrade: {result: "skipped"}}
  ]
}' >"$dist/${PREFIX}.installed-system-evidence.build.json"
installed_digest="$(sha256sum "$dist/${PREFIX}.installed-system-evidence.build.json" | awk '{print $1}')"
jq -n --arg file "${PREFIX}.installed-system-evidence.build.json" --arg digest "$installed_digest" '{
  algorithm: "sha256", file: $file, sha256: $digest
}' >"$dist/${PREFIX}.installed-system-checksum.build.json"

for kind in build validate; do
  run_id=1
  [[ "$kind" == "validate" ]] && run_id=2
  jq -n --arg commit "$COMMIT" --arg url "https://github.com/example/openclaw-os/actions/runs/$run_id" --arg kind "$kind" --arg built_at "$built_at" --arg generated_at "$generated_at" '{
    conclusion: "success",
    event: "push",
    headBranch: "main",
    headSha: $commit,
    url: $url,
    workflowName: (if $kind == "build" then "Build ISO" else "Validate" end),
    workflowPath: (if $kind == "build" then ".github/workflows/build-iso.yml" else ".github/workflows/validate.yml" end),
    runAttempt: 1,
    repository: "example/openclaw-os",
    createdAt: $built_at,
    updatedAt: $built_at,
    jobs: (if $kind == "build" then [{
      name: "build-amd64",
      conclusion: "success",
      steps: [{name: "UEFI live-boot smoke test", conclusion: "success"}]
    }] else [] end)
  }' >"$scratch/${kind}-run.json"
done

jq -n --arg commit "$COMMIT" '{
  id: 99,
  name: "openclaw-os-amd64",
  expired: false,
  sizeInBytes: 1024,
  archiveDigest: ("sha256:" + ("d" * 64)),
  workflowRunHeadSha: $commit
}' >"$scratch/artifact.json"

jq -n '[6, 7, 8, 9, 10, 11, 12, 13, 14] | map({
  number: .,
  state: (if . == 12 or . == 14 then "closed" else "open" end),
  url: ("https://github.com/example/openclaw-os/issues/" + tostring)
})' >"$scratch/issues.json"

observed_at="$(date --utc --date='1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
jq -n '[
  {
    state: "rejected",
    user: {login: "unrelated-reviewer"},
    environments: [{name: "alpha-release"}]
  },
  {
    state: "approved",
    user: {login: "release-reviewer"},
    environments: [{name: "alpha-release"}]
  }
]' >"$scratch/approval-history.json"
jq -e \
  --arg run_url https://github.com/example/openclaw-os/actions/runs/3 \
  --arg actor workflow-dispatcher \
  --arg observed_at "$observed_at" \
  --argjson job_id 4 \
  --argjson run_attempt 1 \
  -f "$ROOT_DIR/scripts/resolve-release-approval.jq" \
  "$scratch/approval-history.json" >"$scratch/approval.json"
if jq -e \
    --arg run_url https://github.com/example/openclaw-os/actions/runs/3 \
    --arg actor release-reviewer \
    --arg observed_at "$observed_at" \
    --argjson job_id 4 \
    --argjson run_attempt 1 \
    -f "$ROOT_DIR/scripts/resolve-release-approval.jq" \
    "$scratch/approval-history.json" >/dev/null; then
  echo 'self-approved release review was accepted' >&2
  exit 1
fi

"$ROOT_DIR/scripts/prepare-release-evidence.sh" \
  "$dist" "v$VERSION" "$COMMIT" \
  "$scratch/build-run.json" "$scratch/validate-run.json" \
  "$scratch/artifact.json" \
  "$scratch/issues.json" "$scratch/approval.json" \
  "$ROOT_DIR/docs/releases/${VERSION}.json" \
  example/openclaw-os "$generated_at" \
  https://github.com/example/openclaw-os/actions/runs/3

evidence="$dist/${PREFIX}.release-evidence.json"
jq -e --arg commit "$COMMIT" '
  .sourceCommit == $commit
  and .artifact.testedDigest == .artifact.promotedDigest
  and (.evidence | length == 7)
  and (.issues | length == 9)
' "$evidence" >/dev/null

cp "$scratch/approval.json" "$scratch/invalid-approval.json"
jq '.method = "manual"' "$scratch/invalid-approval.json" \
  >"$scratch/approval.json"
if "$ROOT_DIR/scripts/prepare-release-evidence.sh" \
    "$dist" "v$VERSION" "$COMMIT" \
    "$scratch/build-run.json" "$scratch/validate-run.json" \
    "$scratch/artifact.json" \
    "$scratch/issues.json" "$scratch/approval.json" \
    "$ROOT_DIR/docs/releases/${VERSION}.json" \
    example/openclaw-os "$generated_at" \
    https://github.com/example/openclaw-os/actions/runs/3 >/dev/null 2>&1; then
  echo 'unprotected release approval was accepted' >&2
  exit 1
fi
mv "$scratch/invalid-approval.json" "$scratch/approval.json"

cp "$dist/${PREFIX}.build.json" "$scratch/tampered-build.json"
jq '.gitCommit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$scratch/tampered-build.json" >"$dist/${PREFIX}.build.json"
if "$ROOT_DIR/scripts/prepare-release-evidence.sh" \
    "$dist" "v$VERSION" "$COMMIT" \
    "$scratch/build-run.json" "$scratch/validate-run.json" \
    "$scratch/artifact.json" \
    "$scratch/issues.json" "$scratch/approval.json" \
    "$ROOT_DIR/docs/releases/${VERSION}.json" \
    example/openclaw-os "$generated_at" \
    https://github.com/example/openclaw-os/actions/runs/3 >/dev/null 2>&1; then
  echo 'tampered build manifest was accepted' >&2
  exit 1
fi

echo 'Release evidence tests passed.'
