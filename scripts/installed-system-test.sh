#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: installed-system-test.sh <path-to-iso>

Runs the matrix in tests/installed-system/matrix.json. Each case installs the
ISO to a blank QEMU disk, boots the installed system with the ISO detached,
optionally exercises the pinned OpenClaw upgrade, rollback, and reapply path,
and emits machine-readable evidence.
USAGE
}

ISO_PATH="${1:-}"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || { usage >&2; exit 2; }

for command_name in awk basename cp date git grep jq mktemp python3 \
  realpath rm sha256sum stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_PATH="$(realpath "$ISO_PATH")"
matrix_path="${INSTALLED_SYSTEM_MATRIX:-$repo_root/tests/installed-system/matrix.json}"
diagnostics_root="${INSTALLED_SYSTEM_DIAGNOSTICS_DIR:-$repo_root/dist/installed-system-test}"
install_script="$repo_root/scripts/install-iso-vm.sh"
base_template_dir="$repo_root/tests/install"
upgrade_template="$repo_root/tests/installed-system/verify-installed-upgrade.sh.in"
upgrade_service="$repo_root/tests/installed-system/verify-installed-upgrade.service"

for path in "$matrix_path" "$install_script" "$upgrade_template" "$upgrade_service" \
  "$base_template_dir/verify-installed.sh.in" \
  "$base_template_dir/verify-installed.service"; do
  [[ -f "$path" && ! -L "$path" ]] || {
    printf 'Missing or unsafe installed-system test input: %s\n' "$path" >&2
    exit 1
  }
done
[[ -x "$install_script" ]] || {
  printf 'Installer harness is not executable: %s\n' "$install_script" >&2
  exit 1
}

# shellcheck disable=SC1090,SC1091
source "$repo_root/image/config/includes.chroot/usr/share/openclaw-os/release.env"
expected_os_version="$(cat "$repo_root/VERSION")"
[[ "$expected_os_version" == "$OPENCLAW_OS_VERSION" ]] || {
  printf 'VERSION and release.env disagree: %s != %s\n' \
    "$expected_os_version" "$OPENCLAW_OS_VERSION" >&2
  exit 1
}

jq -e --arg candidate "$OPENCLAW_VERSION" '
  .schemaVersion == 1
  and (.diskSizeGiB | type == "number" and floor == . and . >= 8 and . <= 256)
  and (.installTimeoutSeconds | type == "number" and floor == . and . >= 60)
  and (.bootTimeoutSeconds | type == "number" and floor == . and . >= 60)
  and (.cases | type == "array" and length > 0)
  and (.cases | all(
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,31}$"))
    and (.firmware == "uefi" or .firmware == "bios")
    and (.machine == "q35" or .machine == "pc")
    and (.runUpgradePath | type == "boolean")
    and (
      (.firmware == "uefi" and .machine == "q35")
      or (.firmware == "bios" and .machine == "pc")
    )
  ))
  and (([.cases[].id] | length) == ([.cases[].id] | unique | length))
  and (
    (any(.cases[]; .runUpgradePath) | not)
    or (
      (.upgrade | type == "object")
      and (.upgrade.fromVersion | type == "string" and test("^[0-9A-Za-z._+-]+$"))
      and (.upgrade.fromVersion != $candidate)
      and (.upgrade.fromTarball
        == ("https://registry.npmjs.org/openclaw/-/openclaw-"
          + .upgrade.fromVersion + ".tgz"))
      and (.upgrade.fromIntegrity
        | type == "string" and test("^sha512-[A-Za-z0-9+/=]+$"))
      and (.upgrade.fromReleaseCommit
        | type == "string" and test("^[a-f0-9]{40}$"))
    )
  )
' "$matrix_path" >/dev/null || {
  printf 'Installed-system matrix is invalid: %s\n' "$matrix_path" >&2
  exit 1
}

disk_size_gib="$(jq -r '.diskSizeGiB' "$matrix_path")"
install_timeout="$(jq -r '.installTimeoutSeconds' "$matrix_path")"
boot_timeout="$(jq -r '.bootTimeoutSeconds' "$matrix_path")"
upgrade_requested="$(jq -r 'any(.cases[]; .runUpgradePath)' "$matrix_path")"
upgrade_from_version="$(jq -r '.upgrade.fromVersion // ""' "$matrix_path")"
upgrade_from_tarball="$(jq -r '.upgrade.fromTarball // ""' "$matrix_path")"
upgrade_from_integrity="$(jq -r '.upgrade.fromIntegrity // ""' "$matrix_path")"
upgrade_from_commit="$(jq -r '.upgrade.fromReleaseCommit // ""' "$matrix_path")"

mkdir -p "$diagnostics_root" "$repo_root/dist"
scratch_dir="$(mktemp -d)"
original_verify="$scratch_dir/verify-installed.sh.in"
original_service="$scratch_dir/verify-installed.service"
results_file="$scratch_dir/case-results.ndjson"
cp --preserve=mode,timestamps \
  "$base_template_dir/verify-installed.sh.in" "$original_verify"
cp --preserve=mode,timestamps \
  "$base_template_dir/verify-installed.service" "$original_service"
original_verify_sha="$(sha256sum "$original_verify" | awk '{print $1}')"
original_service_sha="$(sha256sum "$original_service" | awk '{print $1}')"
templates_restored=false

restore_templates() {
  if [[ "$templates_restored" == "true" ]]; then
    return 0
  fi
  cp --preserve=mode,timestamps "$original_verify" \
    "$base_template_dir/verify-installed.sh.in"
  cp --preserve=mode,timestamps "$original_service" \
    "$base_template_dir/verify-installed.service"
  templates_restored=true
}

cleanup() {
  local status=$?
  restore_templates || status=1
  rm -rf "$scratch_dir"
  return "$status"
}
trap cleanup EXIT

render_upgrade_template() {
  local case_id="$1"
  local machine="$2"
  local run_upgrade="$3"
  local destination="$4"

  TEMPLATE_SOURCE="$upgrade_template" \
  TEMPLATE_DESTINATION="$destination" \
  TEST_CASE_ID="$case_id" \
  TEST_MACHINE="$machine" \
  TEST_RUN_UPGRADE="$run_upgrade" \
  TEST_UPGRADE_FROM_VERSION="$upgrade_from_version" \
  TEST_UPGRADE_FROM_TARBALL="$upgrade_from_tarball" \
  TEST_UPGRADE_FROM_INTEGRITY="$upgrade_from_integrity" \
  TEST_UPGRADE_FROM_COMMIT="$upgrade_from_commit" \
  python3 <<'PY'
from pathlib import Path
import os

source = Path(os.environ["TEMPLATE_SOURCE"]).read_text()
replacements = {
    "@CASE_ID@": os.environ["TEST_CASE_ID"],
    "@MACHINE@": os.environ["TEST_MACHINE"],
    "@RUN_UPGRADE_PATH@": os.environ["TEST_RUN_UPGRADE"],
    "@UPGRADE_FROM_VERSION@": os.environ["TEST_UPGRADE_FROM_VERSION"],
    "@UPGRADE_FROM_TARBALL@": os.environ["TEST_UPGRADE_FROM_TARBALL"],
    "@UPGRADE_FROM_INTEGRITY@": os.environ["TEST_UPGRADE_FROM_INTEGRITY"],
    "@UPGRADE_FROM_RELEASE_COMMIT@": os.environ["TEST_UPGRADE_FROM_COMMIT"],
}
for token, value in replacements.items():
    source = source.replace(token, value)
for token in replacements:
    if token in source:
        raise SystemExit(f"unresolved installed-system token: {token}")
Path(os.environ["TEMPLATE_DESTINATION"]).write_text(source)
PY
}

source_iso_sha="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
source_iso_size="$(stat -c '%s' "$ISO_PATH")"
matrix_sha="$(sha256sum "$matrix_path" | awk '{print $1}')"
tested_commit="${GITHUB_SHA:-$(git -C "$repo_root" rev-parse HEAD)}"
[[ "$tested_commit" =~ ^[a-f0-9]{40}$ ]] || {
  printf 'Could not determine the tested commit SHA.\n' >&2
  exit 1
}

while IFS= read -r case_json; do
  case_id="$(jq -r '.id' <<<"$case_json")"
  firmware="$(jq -r '.firmware' <<<"$case_json")"
  machine="$(jq -r '.machine' <<<"$case_json")"
  run_upgrade="$(jq -r '.runUpgradePath' <<<"$case_json")"
  case_diagnostics="$diagnostics_root/$case_id"
  case_result="$case_diagnostics/case-result.json"

  mkdir -p "$case_diagnostics"
  render_upgrade_template \
    "$case_id" "$machine" "$run_upgrade" \
    "$base_template_dir/verify-installed.sh.in"
  cp "$upgrade_service" "$base_template_dir/verify-installed.service"

  printf 'Running installed-system case %s (%s, %s, upgrade=%s)...\n' \
    "$case_id" "$firmware" "$machine" "$run_upgrade"

  INSTALL_TIMEOUT_SECONDS="$install_timeout" \
  INSTALLED_BOOT_TIMEOUT_SECONDS="$boot_timeout" \
  INSTALL_DISK_SIZE="${disk_size_gib}G" \
  INSTALL_TEST_DIAGNOSTICS_DIR="$case_diagnostics" \
    "$install_script" "$ISO_PATH" "$firmware"

  current_iso_sha="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  [[ "$current_iso_sha" == "$source_iso_sha" ]] || {
    printf 'Source ISO changed during installed-system case %s.\n' "$case_id" >&2
    exit 1
  }

  marker="$(
    grep -F 'OPENCLAW_OS_INSTALLED_BOOT_OK ' \
      "$case_diagnostics/installed-serial.log" | tail -n 1
  )"
  [[ -n "$marker" ]] || {
    printf 'Installed-system case %s produced no success marker.\n' "$case_id" >&2
    exit 1
  }
  grep -Fq "case=$case_id" <<<"$marker" || {
    printf 'Installed-system case marker does not match %s.\n' "$case_id" >&2
    exit 1
  }
  grep -Fq "firmware=$firmware" <<<"$marker" || {
    printf 'Installed-system firmware marker does not match %s.\n' "$firmware" >&2
    exit 1
  }
  grep -Fq "machine=$machine" <<<"$marker" || {
    printf 'Installed-system machine marker does not match %s.\n' "$machine" >&2
    exit 1
  }

  expected_upgrade_result=skipped
  if [[ "$run_upgrade" == "true" ]]; then
    expected_upgrade_result=passed
  fi
  grep -Fq "upgrade=$expected_upgrade_result" <<<"$marker" || {
    printf 'Installed-system upgrade marker did not report %s.\n' \
      "$expected_upgrade_result" >&2
    exit 1
  }

  jq -n \
    --arg id "$case_id" \
    --arg firmware "$firmware" \
    --arg machine "$machine" \
    --arg status passed \
    --arg marker "$marker" \
    --arg sourceIsoSha256 "$source_iso_sha" \
    --arg osVersion "$OPENCLAW_OS_VERSION" \
    --arg nodeVersion "$NODE_VERSION" \
    --arg candidateVersion "$OPENCLAW_VERSION" \
    --arg candidateTarball "$OPENCLAW_TARBALL_URL" \
    --arg candidateIntegrity "$OPENCLAW_NPM_INTEGRITY" \
    --arg candidateCommit "$OPENCLAW_RELEASE_COMMIT" \
    --arg fromVersion "$upgrade_from_version" \
    --arg fromTarball "$upgrade_from_tarball" \
    --arg fromIntegrity "$upgrade_from_integrity" \
    --arg fromCommit "$upgrade_from_commit" \
    --arg upgradeResult "$expected_upgrade_result" \
    --argjson runUpgradePath "$run_upgrade" \
    --argjson diskSizeGiB "$disk_size_gib" \
    --argjson installTimeoutSeconds "$install_timeout" \
    --argjson bootTimeoutSeconds "$boot_timeout" \
    '{
      id: $id,
      firmware: $firmware,
      machine: $machine,
      status: $status,
      marker: $marker,
      sourceIsoSha256: $sourceIsoSha256,
      install: {
        diskSizeGiB: $diskSizeGiB,
        installTimeoutSeconds: $installTimeoutSeconds,
        bootTimeoutSeconds: $bootTimeoutSeconds
      },
      versions: {
        openclawOs: $osVersion,
        node: $nodeVersion,
        candidateOpenclaw: $candidateVersion
      },
      upgrade: (
        if $runUpgradePath then {
          requested: true,
          result: $upgradeResult,
          from: {
            version: $fromVersion,
            tarball: $fromTarball,
            integrity: $fromIntegrity,
            releaseCommit: $fromCommit
          },
          candidate: {
            version: $candidateVersion,
            tarball: $candidateTarball,
            integrity: $candidateIntegrity,
            releaseCommit: $candidateCommit
          },
          sequence: [
            "activate-previous",
            "upgrade-candidate",
            "rollback-previous",
            "reapply-candidate"
          ]
        } else {
          requested: false,
          result: $upgradeResult
        } end
      )
    }' >"$case_result"

  jq -c . "$case_result" >>"$results_file"
done < <(jq -c '.cases[]' "$matrix_path")

restore_templates
[[ "$(sha256sum "$base_template_dir/verify-installed.sh.in" | awk '{print $1}')" \
  == "$original_verify_sha" ]] || {
  printf 'Installed-system test did not restore verify-installed.sh.in.\n' >&2
  exit 1
}
[[ "$(sha256sum "$base_template_dir/verify-installed.service" | awk '{print $1}')" \
  == "$original_service_sha" ]] || {
  printf 'Installed-system test did not restore verify-installed.service.\n' >&2
  exit 1
}

evidence_path="${INSTALLED_SYSTEM_EVIDENCE_PATH:-$repo_root/dist/openclaw-os-${OPENCLAW_OS_VERSION}-amd64.installed-system-evidence.build.json}"
checksum_path="${INSTALLED_SYSTEM_CHECKSUM_PATH:-$repo_root/dist/openclaw-os-${OPENCLAW_OS_VERSION}-amd64.installed-system-checksum.build.json}"
mkdir -p "$(dirname "$evidence_path")" "$(dirname "$checksum_path")"
generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg generatedAt "$generated_at" \
  --arg repository "jason-allen-oneal/openclaw-os" \
  --arg commit "$tested_commit" \
  --arg isoName "$(basename "$ISO_PATH")" \
  --argjson isoSizeBytes "$source_iso_size" \
  --arg isoSha256 "$source_iso_sha" \
  --arg matrixPath "${matrix_path#"$repo_root"/}" \
  --arg matrixSha256 "$matrix_sha" \
  --arg osVersion "$OPENCLAW_OS_VERSION" \
  --arg nodeVersion "$NODE_VERSION" \
  --arg candidateVersion "$OPENCLAW_VERSION" \
  --arg candidateTarball "$OPENCLAW_TARBALL_URL" \
  --arg candidateIntegrity "$OPENCLAW_NPM_INTEGRITY" \
  --arg candidateCommit "$OPENCLAW_RELEASE_COMMIT" \
  --arg fromVersion "$upgrade_from_version" \
  --arg fromTarball "$upgrade_from_tarball" \
  --arg fromIntegrity "$upgrade_from_integrity" \
  --arg fromCommit "$upgrade_from_commit" \
  --argjson upgradeRequested "$upgrade_requested" \
  --slurpfile cases "$results_file" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    repository: $repository,
    commit: $commit,
    result: "passed",
    sourceIso: {
      name: $isoName,
      sizeBytes: $isoSizeBytes,
      sha256: $isoSha256
    },
    matrix: {
      path: $matrixPath,
      sha256: $matrixSha256
    },
    versions: {
      openclawOs: $osVersion,
      node: $nodeVersion,
      candidateOpenclaw: {
        version: $candidateVersion,
        tarball: $candidateTarball,
        integrity: $candidateIntegrity,
        releaseCommit: $candidateCommit
      }
    },
    upgrade: (
      if $upgradeRequested then {
        requested: true,
        result: "passed",
        from: {
          version: $fromVersion,
          tarball: $fromTarball,
          integrity: $fromIntegrity,
          releaseCommit: $fromCommit
        },
        candidateVersion: $candidateVersion
      } else {
        requested: false,
        result: "skipped"
      } end
    ),
    cases: $cases
  }' >"$evidence_path"

evidence_sha="$(sha256sum "$evidence_path" | awk '{print $1}')"
jq -n \
  --arg algorithm sha256 \
  --arg file "$(basename "$evidence_path")" \
  --arg sha256 "$evidence_sha" \
  '{algorithm: $algorithm, file: $file, sha256: $sha256}' \
  >"$checksum_path"

cp "$evidence_path" "$diagnostics_root/$(basename "$evidence_path")"
cp "$checksum_path" "$diagnostics_root/$(basename "$checksum_path")"

printf 'Installed-system matrix passed. Evidence: %s\n' "$evidence_path"
