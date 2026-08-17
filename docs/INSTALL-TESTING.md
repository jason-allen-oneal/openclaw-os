# Installed-system test gate

OpenClaw OS release artifacts are verified as installed appliances, not only as bootable live media.

The installed-system gate runs after ISO construction and the UEFI live-media smoke test. It generates CI-only installer input at runtime, installs to fresh virtual disks under UEFI and legacy BIOS, detaches the ISO, boots each installed disk, and verifies the appliance state.

The UEFI case also installs OpenClaw 2026.6.33, upgrades to the pinned candidate, rolls back to 2026.6.33, and applies the candidate again.

## Trust boundary

The production ISO is never modified in place. Preseed data, the CI user, password hash, verification token, and test service are created under the runner temporary directory and injected only into a temporary ISO copy or the resulting test disk. Static validation rejects CI installer material under `image/`.

The source ISO digest is recorded before testing and checked again after every case. The verified release artifact is uploaded only when the live-media boot test and all installed-system cases succeed.

## Installed checks

The installed gate verifies:

- the root filesystem is a disk-backed filesystem, not the live overlay
- OpenClaw OS identity and version
- partitioning and the expected UEFI or BIOS boot path
- the installed bootloader
- pinned Node.js and OpenClaw releases
- NetworkManager, nftables, Gateway, hostd, and controller enablement
- nftables configuration syntax
- masked SSH service
- absence of onboarding state and Gateway credentials
- the Gateway remains stopped before onboarding

## Diagnostics and evidence

Each firmware case retains QEMU commands, serial logs, QEMU logs, temporary-media construction logs, disk metadata, disk consistency output, and private preseed HTTP logs. Random password hashes and verification tokens are removed before upload. Virtual disks and temporary installer ISOs are not uploaded.

A machine-readable evidence document records the tested commit, source ISO digest, OpenClaw OS version, previous and candidate OpenClaw versions, firmware cases, and upgrade-path result. It and its SHA-256 checksum are included with the verified ISO artifact.

## Local execution

The gate requires QEMU, OVMF, qemu-img, xorriso, bsdtar, Python, OpenSSL, curl, jq, and enough free space for two temporary 24 GiB sparse disks.

```bash
make iso
make installed-system
```

The default diagnostics directory is `dist/installed-system-test`. Environment variables can override the matrix, diagnostics directory, and evidence destination.
