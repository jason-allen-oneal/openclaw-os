# OpenClaw OS

OpenClaw OS is a Debian 13 appliance distribution dedicated to running
OpenClaw as an always-on, single-operator gateway.

The repository builds an installable amd64 hybrid ISO with a pinned Node.js 24
LTS runtime, a pinned OpenClaw extended-stable release, a hardened systemd
service, rootless Podman-backed tool sandboxes, nftables, verified backups,
periodic security checks, staged OpenClaw upgrades, automatic code rollback, an
SPDX SBOM, and a local appliance console.

The build never reads from a developer's OpenClaw checkout or home-directory
OpenClaw state. It downloads exact upstream artifacts into an isolated image
build and validates them before installation.

## Current pins

| Component | Version |
| --- | --- |
| OpenClaw OS | 0.1.0 |
| Debian | 13 `trixie` |
| Node.js | 24.15.0 LTS |
| OpenClaw | 2026.6.34 extended-stable |
| Sandbox base | Debian 12 bookworm-slim, digest pinned |

The Node.js archives are checked against pinned SHA-256 values. OpenClaw is
checked against the npm registry SHA-512 SRI, the package version, the exact
registry tarball URL, published registry signature metadata, the corresponding
GitHub release SRI, and the pinned release commit used by the image.

## Implemented appliance behavior

OpenClaw runs as the unprivileged `openclaw` system account. The Gateway cannot
write to `/opt`, `/usr`, or `/etc`. Its active state and configuration live in
`/var/lib/openclaw`, while agent workspaces live in `/srv/openclaw`.

The Gateway binds to loopback by default. Inbound traffic is denied by nftables
unless the operator explicitly permits a port. The appliance LAN command opens
the Gateway only to private IPv4, carrier-grade NAT or tailnet, IPv6 ULA, and
IPv6 link-local source ranges. It also requires token or password authentication
before changing the bind mode. SSH is installed but disabled. Enabling SSH
requires an authorized key, and both root login and password authentication are
disabled.

OpenClaw's Docker sandbox backend is routed through a compatibility wrapper to
a rootless Podman API service owned by the `openclaw` account. The initial
sandbox policy is:

```text
mode: all
scope: agent
workspaceAccess: rw
network: none
readOnlyRoot: true
capDrop: ALL
```

The Gateway remains on the host. Rootless containers, systemd restrictions,
and the firewall reduce impact, but they do not create a hostile multi-tenant
security boundary.

## Build on Debian 13

Install the build dependencies:

```bash
sudo apt update
sudo apt install --yes \
  live-build debootstrap xorriso squashfs-tools \
  grub-pc-bin grub-efi-amd64-bin isolinux syslinux-common syslinux-utils \
  mtools dosfstools \
  curl jq ca-certificates openssl shellcheck nftables \
  qemu-system-x86 ovmf
```

Validate source and upstream pins, run the tests, then build and smoke-test the
ISO:

```bash
make validate
make test
make verify-artifacts
make iso
make smoke
```

Generated files are written to `dist/`:

```text
dist/openclaw-os-0.1.0-amd64.iso
dist/openclaw-os-0.1.0-amd64.iso.sha256
dist/openclaw-os-0.1.0-amd64.sbom.spdx.json
dist/openclaw-os-0.1.0-amd64.sbom.spdx.json.sha256
dist/openclaw-os-0.1.0-amd64.build.json
```

The GitHub Actions build uses a digest-pinned Debian 13 container with Debian's
current `live-build`, then boots the resulting ISO under UEFI QEMU and waits for
the `OPENCLAW_OS_BOOT_OK` readiness marker. The workflow uploads the ISO, SBOM,
checksums, build metadata, and build log as one artifact.

## Install and first boot

Boot the ISO and use the included Debian installer. After the installed system
reboots, OpenClaw OS starts its appliance console on `tty1`. A standard Linux
maintenance login remains available on `tty2`.

The appliance console can:

- Run OpenClaw onboarding without installing a competing user service.
- Build the pinned rootless sandbox image.
- Start, stop, restart, and inspect the Gateway.
- Switch Control UI access between loopback and authenticated LAN mode.
- Configure networking through `nmtui`.
- Enable or disable key-only SSH.
- Create and verify OpenClaw backups.
- Run configuration, secret, and security audits.
- Check, stage, apply, cancel, and roll back OpenClaw releases.

The same operations are available from a maintenance shell:

```bash
sudo openclaw-appliance status
sudo openclaw-appliance setup
sudo openclaw-appliance sandbox build
sudo openclaw-appliance access lan
sudo openclaw-appliance backup
sudo openclaw-appliance audit deep
sudo openclaw-appliance update status
sudo openclaw-appliance update check extended-stable
sudo openclaw-appliance releases
```

Use `sudo openclaw ...` for direct OpenClaw CLI access against the appliance
state directory.

## Safe OpenClaw upgrades

Debian security updates are handled by unattended-upgrades. OpenClaw's own
startup update check and background auto-update remain disabled because the
appliance owns the OpenClaw code transaction.

OpenClaw upgrades are split into reviewable phases:

```bash
sudo openclaw-appliance update check extended-stable
sudo openclaw-appliance update stage <exact-version>
sudo openclaw-appliance update status
sudo openclaw-appliance update apply
```

`check` verifies npm and GitHub release metadata without changing the system.
`stage` installs and validates an exact candidate under
`/opt/openclaw/releases/<version>` without switching the active symlink or
restarting the Gateway. `apply` uses the recorded exact staged release, creates
a verified backup, switches the symlink, and runs a health check. It preserves
whether the Gateway was running or stopped before the transaction.

By default, only versions in `config/openclaw-compatibility.json` may be staged
or activated. A power user can test an unlisted release only by naming the exact
version and supplying `--allow-untested`. Moving npm tags cannot use that
exception.

If candidate validation or health checking fails, OpenClaw OS restores the prior
code symlink and prior Gateway service state. Code rollback does not
automatically rewind OpenClaw state. The pre-activation verified backup remains
available because restoring state can rewind credentials, channel ratchets,
approvals, delivery queues, conversations, and workspaces.

The full operating procedure and failure model are in
[`docs/UPDATES.md`](docs/UPDATES.md).

## Backups and audits

A daily systemd timer runs `openclaw backup create --verify`. Backups are stored
under `/var/lib/openclaw/backups` with a default 30-day retention policy.

A weekly timer writes configuration validation, `secrets audit --check`, and
security audit output under `/var/log/openclaw/audits`. Deep live audits can be
started manually through the console or CLI.

Backups can contain credentials, channel state, conversations, and workspace
data. Protect exported backups with encryption and access controls equivalent
to the running appliance.

## Repository metadata

The canonical GitHub description, homepage, and topics are stored in
`.github/repository-metadata.json`. A repository administrator can synchronize
them after authenticating GitHub CLI:

```bash
make sync-repo-metadata
```

## Project status

Version 0.1.0 is the first functional amd64 image profile. It is intended for
VM and lab deployment before production use. The source validation, upstream
artifact verification, ISO pipeline, UEFI live-boot smoke test, appliance
runtime, firewall, rootless sandbox bridge, console, backups, audits, SBOM,
staged OpenClaw update transaction, compatibility gate, and code rollback are
implemented.

The automated test does not complete a full interactive Debian installation.
Physical hardware coverage, browser sandbox images, ARM64 installer media,
measured boot, secure boot signing, disk-encryption automation, and A/B base-OS
updates remain later milestones.
