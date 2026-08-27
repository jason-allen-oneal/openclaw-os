# Installed-system test gate

OpenClaw OS release artifacts are verified as installed appliances, not only as
bootable live media.

The gate runs after ISO construction and the UEFI live-media smoke test. Its
source of truth is `tests/installed-system/matrix.json`. The runner validates
that matrix, executes every declared firmware case, verifies that the source ISO
digest never changes, and emits machine-readable evidence only after all cases
pass.

## Current matrix

The current matrix declares:

- a UEFI `q35` installation with the OpenClaw release transaction enabled
- a legacy BIOS `pc` installation without the release transaction
- a 24 GiB sparse disk for each case
- explicit installation and installed-boot timeouts
- the exact previous OpenClaw version, npm tarball, SRI value, and release commit

The UEFI case starts from the OpenClaw version pinned in the image, then:

1. verifies the previous release metadata against npm and the upstream GitHub
   release record
2. stages and activates the exact previous OpenClaw version
3. stages and applies the candidate version
4. rolls back to the previous version
5. stages and applies the candidate again
6. verifies the candidate is active and the Gateway remains stopped before
   onboarding

This tests the OpenClaw application transaction inside the appliance. It does
not claim an upgrade from a previous OpenClaw OS image. That separate base-OS
upgrade path requires a published prior OpenClaw OS artifact.

## Trust boundary

The production ISO is never modified in place. Preseed data, the CI user,
password hash, generated verifier, and test service exist only in runner
temporary storage and on the disposable test disk.

The matrix runner temporarily replaces the test templates under `tests/install`
for each case because the existing installer harness reads from that directory.
It saves byte-for-byte copies first, restores them under an exit trap, and
verifies the restored SHA-256 values before producing evidence.

Static validation rejects CI installer material under `image/`. Password hashes
are generated per run, and retained preseed diagnostics are redacted.

## Installed checks

Every installed case verifies:

- the root filesystem is disk-backed rather than the live overlay
- OpenClaw OS identity and version
- partitioning and the expected UEFI or BIOS boot path
- the installed bootloader
- pinned Node.js and OpenClaw releases
- NetworkManager, nftables, Gateway, hostd, and controller enablement
- nftables configuration syntax
- masked SSH service
- absence of onboarding state and Gateway credentials
- the Gateway remains stopped before onboarding

## Evidence

A passing run writes these files to `dist/`:

```text
openclaw-os-<os-version>-amd64.installed-system-evidence.build.json
openclaw-os-<os-version>-amd64.installed-system-checksum.build.json
```

Both names match the existing verified artifact glob
`openclaw-os-*.build.json`, so they are included with the ISO without a second
artifact path.

The evidence records:

- repository and tested commit
- source ISO name, size, and SHA-256
- matrix path and SHA-256
- OpenClaw OS, Node.js, previous OpenClaw, and candidate OpenClaw metadata
- every firmware case and its exact success marker
- whether the upgrade, rollback, and reapply sequence ran and passed

The checksum document identifies the evidence filename and its SHA-256 digest.
Copies are also retained with the installed-system diagnostics.

## Failure behavior

A failed installation, boot, metadata check, update, rollback, reapply, or ISO
immutability check fails `build-amd64`. No verified ISO artifact is uploaded.

Each case retains installer and installed-system serial logs, QEMU logs, preseed
HTTP logs, command lines, firmware metadata, disk metadata, the rendered
verifier, and a redacted preseed. Virtual disks and temporary installer inputs
are deleted unless an operator explicitly enables local retention.

## Local execution

The full gate requires QEMU, OVMF, xorriso, Python, OpenSSL, curl, jq, and enough
free space for the matrix's sparse disks.

```bash
make iso
make installed-system
```

To run the live-media smoke test followed by the same installed-system matrix:

```bash
make install-smoke
```

Environment variables can override the matrix, diagnostics directory, evidence
path, and checksum path for local investigation.
