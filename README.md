# OpenClaw OS

OpenClaw OS is a Debian 13 appliance distribution dedicated to running
OpenClaw as an always-on, single-operator gateway.

It is intended for people who want OpenClaw on a mini PC or virtual machine
without maintaining a general-purpose Linux server. The appliance owns
installation, service health, privilege policy, backups, audits, OpenClaw
updates, rollback, and recovery.

## Current status

Version `0.1.0` is a technical alpha for amd64 virtual machines and lab systems.
It is not yet a stable production appliance.

Implemented today:

- installable Debian 13 `trixie` hybrid ISO
- pinned Node.js 24 LTS and pinned OpenClaw extended-stable release
- unprivileged OpenClaw Gateway service
- rootless Podman-backed tool sandboxes
- nftables default-deny inbound policy
- local appliance console and maintenance CLI
- locked, connected, developer, power-user, and host-control profiles
- verified backups and periodic audits
- opt-in staged OpenClaw updates with code rollback and failed-candidate quarantine
- SPDX 2.3 SBOM and artifact checksums
- UEFI QEMU live-boot verification with retained failure diagnostics
- matrix-driven blank-disk installation under UEFI and legacy BIOS
- installed-disk reboot verification with the source ISO detached
- exact OpenClaw stage, apply, rollback, and reapply verification
- machine-readable installed-system evidence and checksum metadata
- machine-readable alpha, beta, and stable promotion policy
- protected `main` with required validation and ISO checks
- automatic deletion of safely merged transient branches

Still required before a stable release:

- production release-signing trust
- evidence-backed OpenClaw compatibility records
- tested upgrades from supported prior OpenClaw OS releases
- transactional base-OS rollback
- Secure Boot signing and tamper-rejection testing
- physical hardware coverage

## Current pins

| Component | Version |
| --- | --- |
| OpenClaw OS | 0.1.0 |
| Debian | 13 `trixie` |
| Node.js | 24.15.0 LTS |
| OpenClaw | 2026.6.34 extended-stable |
| Sandbox base | Debian 12 bookworm-slim, digest pinned |

The build never reads from a developer OpenClaw checkout or home-directory
OpenClaw state. It downloads exact upstream artifacts in an isolated image
build and verifies hashes, integrity metadata, package identity, signatures,
and release metadata before installation.

## Security and privilege model

OpenClaw runs as the unprivileged `openclaw` system account. Mutable state lives
under `/var/lib/openclaw`, and workspaces live under `/srv/openclaw`. The
Gateway cannot write to `/opt`, `/usr`, or `/etc`.

The Gateway binds to loopback by default. Inbound traffic is denied unless the
operator explicitly permits it. SSH is installed but masked. Enabling SSH
requires a public key, while root login and password authentication remain
disabled.

The default sandbox policy is:

```text
mode: all
scope: agent
workspaceAccess: rw
network: none
readOnlyRoot: true
capDrop: ALL
```

OpenClaw OS includes explicit privilege profiles:

| Profile | Intended use |
| --- | --- |
| `locked` | chat and tightly restricted workspace activity |
| `connected` | sandboxed tools with controlled network access |
| `developer` | development tools and broader workspace access |
| `power-user` | advanced OpenClaw capabilities with explicit risk acknowledgement |
| `host` | narrowly approved host-control operations through the appliance boundary |

Profiles are visible configuration, not hidden security claims. Rootless
containers, systemd hardening, and the firewall reduce blast radius, but they do
not provide hostile multi-tenant isolation. The supported model is one trusted
operator per appliance.

See [`docs/POLICIES.md`](docs/POLICIES.md).

## Build on Debian 13

Install the build dependencies:

```bash
sudo apt update
sudo apt install --yes \
  live-build debootstrap xorriso squashfs-tools \
  grub-pc-bin grub-efi-amd64-bin isolinux syslinux-common syslinux-utils \
  mtools dosfstools \
  curl jq ca-certificates openssl python3 shellcheck nftables \
  qemu-system-x86 ovmf
```

Validate the source, run tests, verify upstream artifacts, build the ISO, and
boot it under UEFI QEMU:

```bash
make validate
make test
make verify-artifacts
make iso
make smoke
```

Run only the matrix-driven installed-system gate against an existing ISO:

```bash
make installed-system
```

Run the live-media smoke test followed by the installed-system matrix:

```bash
make install-smoke
```

Generated release files include:

```text
dist/openclaw-os-0.1.0-amd64.iso
dist/openclaw-os-0.1.0-amd64.iso.sha256
dist/openclaw-os-0.1.0-amd64.sbom.spdx.json
dist/openclaw-os-0.1.0-amd64.sbom.spdx.json.sha256
dist/openclaw-os-0.1.0-amd64.build.json
dist/openclaw-os-0.1.0-amd64.installed-system-evidence.build.json
dist/openclaw-os-0.1.0-amd64.installed-system-checksum.build.json
```

The verified GitHub Actions artifact is uploaded only after these gates pass:

1. Source validation and unit tests.
2. Upstream artifact verification.
3. Generated GRUB configuration validation.
4. UEFI live-ISO boot and readiness marker.
5. Noninteractive installation to a fresh UEFI virtual disk.
6. Reboot from the installed UEFI disk with the ISO detached.
7. Noninteractive installation to a fresh legacy-BIOS virtual disk.
8. Reboot from the installed BIOS disk with the ISO detached.
9. Installed-system verification of partitioning, bootloader, service
   enablement, onboarding state, firewall syntax, Node.js, OpenClaw, and
   OpenClaw OS versions.
10. The matrix-selected OpenClaw transaction: activate the exact previous
    version, apply the candidate, roll back, and apply the candidate again.
11. Machine-readable evidence generation and evidence checksum verification.

The installed-system matrix is
[`tests/installed-system/matrix.json`](tests/installed-system/matrix.json).
Unknown or malformed matrix input fails closed.

CI generates a unique disposable password hash at runtime, serves the preseed
only from the runner, stores only a redacted preseed in diagnostics, and never
places CI credentials or installer automation under the production `image/`
tree. The source ISO digest is checked after every case.

The OpenClaw transaction tests application-level release switching inside the
current appliance. It does not replace the separate requirement to test an
upgrade from a published prior OpenClaw OS image.

See [`docs/INSTALL-TESTING.md`](docs/INSTALL-TESTING.md).

## Install and first boot

Boot the ISO and use the included Debian installer. After reboot, OpenClaw OS
starts the appliance console on `tty1`. A maintenance login remains available
on `tty2`.

The console and CLI can:

- run OpenClaw onboarding without installing a competing user service
- build the pinned rootless sandbox image
- start, stop, restart, and inspect the Gateway
- switch Control UI access between loopback and authenticated private-LAN mode
- configure networking
- enable or disable key-only SSH
- create and verify backups
- run configuration, secret, and security audits
- select and inspect privilege profiles
- check, stage, apply, cancel, and roll back OpenClaw releases

Common maintenance commands:

```bash
sudo openclaw-appliance status
sudo openclaw-appliance setup
sudo openclaw-appliance sandbox build
sudo openclaw-appliance policy status
sudo openclaw-appliance policy apply developer
sudo openclaw-appliance access lan
sudo openclaw-appliance backup
sudo openclaw-appliance audit deep
sudo openclaw-appliance update status
sudo openclaw-appliance releases
```

Use `sudo openclaw ...` for direct OpenClaw CLI access against appliance state.

## Safe OpenClaw upgrades

Debian security updates are handled separately by unattended-upgrades.
OpenClaw startup checks and background auto-update are disabled because the
appliance owns the OpenClaw code transaction.

Upgrades are opt-in and split into reviewable phases:

```bash
sudo openclaw-appliance update check extended-stable
sudo openclaw-appliance update stage <exact-version>
sudo openclaw-appliance update status
sudo openclaw-appliance update apply
```

`check` is read-only. `stage` downloads, verifies, installs, and validates an
exact candidate without changing the active release or restarting the Gateway.
`apply` activates the staged version and restores the prior code if activation
fails.

Only versions in `config/openclaw-compatibility.json` are accepted by default.
A power user can name an exact unlisted version with `--allow-untested`. This
override does not bypass artifact verification, compatibility checks, backup
requirements when state exists, health checks, or rollback.

Code rollback does not automatically rewind OpenClaw state. Automatic state
rollback could rewind credentials, approvals, channel state, conversations, or
delivery queues.

See [`docs/UPDATES.md`](docs/UPDATES.md).

## Release promotion

OpenClaw OS promotes the same tested artifact through alpha, beta, and stable.
It does not rebuild the ISO during promotion.

```bash
make release-policy
make test-release-gate
```

Release evidence can be evaluated with:

```bash
node scripts/release-gate.mjs evidence \
  config/release-promotion-policy.json \
  path/to/release-evidence.json
```

The gate checks artifact identity, CI status, evidence freshness, soak period,
blocker state, approvals, release notes, and rollback information. Waivers are
not accepted. A clean VM installation is required for alpha. A tested upgrade
from a supported prior OpenClaw OS release remains required for beta and cannot
be claimed until a prior release artifact exists.

See [`docs/RELEASES.md`](docs/RELEASES.md).

## Backups and audits

A daily timer runs `openclaw backup create --verify`. Backups are stored under
`/var/lib/openclaw/backups` with a default 30-day retention policy.

A weekly timer records configuration validation, secret audit, and security
audit results under `/var/log/openclaw/audits`. Backups may contain credentials,
channel state, conversations, and workspace data, so exported copies require
encryption and access controls equivalent to the running appliance.

## Repository administration

Canonical GitHub metadata is stored in `.github/repository-metadata.json`.
Canonical branch protection and merge settings are stored in
`config/repository-protection.json`.

```bash
make apply-repo-settings
```

The policy requires pull requests, current branches, `validate` and
`build-amd64`, administrator enforcement, resolved review conversations, and
zero approving reviews while there is one maintainer. It blocks force pushes
and deletion of `main`, enables PR branch updating, and deletes merged branches
automatically.

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/INSTALL-TESTING.md`](docs/INSTALL-TESTING.md)
- [`docs/POLICIES.md`](docs/POLICIES.md)
- [`docs/UPDATES.md`](docs/UPDATES.md)
- [`docs/RELEASES.md`](docs/RELEASES.md)
- [`SECURITY.md`](SECURITY.md)
