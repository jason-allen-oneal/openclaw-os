# OpenClaw OS architecture

## Design goal

OpenClaw OS is an appliance, not a general desktop distribution. Debian owns
the kernel, package manager, installer, hardware support, and base security
updates. This repository owns the image profile and the OpenClaw-specific
runtime, policy, services, console, backups, audits, and release transaction.

The build is independent of any local OpenClaw checkout. Upstream Node.js and
OpenClaw artifacts are fetched from their release endpoints and validated from
pinned metadata.

## Filesystem layout

```text
/etc/openclaw/                    Appliance policy and firewall allowlists
/opt/node/releases/<version>/    Immutable Node.js runtimes
/opt/node/current                Active Node.js symlink
/opt/openclaw/releases/<version> Immutable npm global prefixes
/opt/openclaw/current            Active OpenClaw symlink
/var/lib/openclaw/state/         OpenClaw state and active config
/var/lib/openclaw/backups/       Verified local backup archives
/var/lib/openclaw/containers/    Rootless Podman storage
/srv/openclaw/workspaces/        Agent workspaces
/var/log/openclaw/audits/        Local audit output
/run/openclaw/                   Podman API socket and runtime data
/usr/share/openclaw-os/          Image metadata, defaults, sandbox source, SBOM
```

## Service boundary

`openclaw.service` runs as the `openclaw` account. It has no Linux capabilities,
uses `NoNewPrivileges`, and receives write access only to state, workspaces,
logs, and runtime directories. It is conditional on a real, non-symlinked
OpenClaw configuration file, so it cannot start before onboarding.

OpenClaw's bundled sandbox backend invokes a command named `docker`. OpenClaw OS
provides that command as a compatibility wrapper around the remote Podman
client. The client connects to `openclaw-podman.service`, a rootless Podman API
service owned by the same unprivileged account. User-namespace setup therefore
occurs outside the more restrictive Gateway service, without exposing a
root-owned Docker socket.

## Configuration ownership

The active config is a regular file at:

```text
/var/lib/openclaw/state/openclaw.json
```

The environment sets `OPENCLAW_SERVICE_REPAIR_POLICY=external`, which prevents
OpenClaw repair operations from replacing the appliance-managed system service
with a user service.

Onboarding creates the initial configuration. The appliance applies its safety
patch through `openclaw config patch`, then asks OpenClaw to validate the result.
OpenClaw remains the authority for its own configuration schema.

The safety patch enables all-session sandboxing, disables elevated execution,
disables sandbox network access, turns off mDNS discovery, keeps the Gateway on
loopback, selects extended-stable, and disables OpenClaw-managed background code
updates.

## Network boundary

The base nftables policy drops inbound and forwarded traffic and permits
outbound traffic. Loopback, established traffic, ICMP, ICMPv6, and DHCP replies
are allowed.

Two TCP allowlists are maintained:

- `allowed_tcp_ports` permits an operator-selected port from any source.
- `allowed_lan_tcp_ports` permits a port only from RFC1918, carrier-grade NAT or
  tailnet, IPv4 link-local, IPv6 ULA, and IPv6 link-local sources.

Authenticated Gateway LAN exposure uses the second list. Key-only SSH uses the
first list when the operator explicitly enables it.

## Artifact trust path

The image pins each Node.js archive by SHA-256. OpenClaw installation requires:

- An exact version and exact npm registry tarball URL.
- A SHA-512 SRI from pinned or resolved registry metadata.
- Non-empty npm registry signature metadata.
- The same SRI in the corresponding published GitHub release record.
- The expected release commit for the version embedded in the OS image.
- A package archive whose `package.json` reports the expected version.
- A staged `openclaw --version` result before activation.

npm installation runs with isolated user, global, cache, and home paths so host
npm configuration does not influence the transaction.

## Update transaction

Core updates are installed into a new versioned prefix. Existing state is backed
up first. Configuration is validated with the candidate binary before the
active code symlink changes. After activation, systemd restarts the Gateway and
the appliance checks the health RPC. A failed activation restores the previous
code symlink and attempts to restart the prior release.

The appliance retains the active release plus the newest configured number of
fallback releases. State rollback is deliberately separate from code rollback.

## Build and test boundary

GitHub Actions runs the image build in a privileged, digest-pinned Debian 13
container so Debian's current `live-build` is used instead of the older Ubuntu
package. Actions are pinned by full commit SHA.

Static validation includes shell syntax, ShellCheck, release pin shape, action
pins, service hardening, credential-pattern checks, firewall rendering, and
appliance unit tests. The unit tests exercise registry metadata rejection, SRI
verification, release retention, release-record parsing, and firewall output.

The image build emits an SPDX 2.3 SBOM from the final chroot package database and
the separately installed Node.js and OpenClaw runtimes. After the ISO is built,
a UEFI QEMU smoke test boots the live environment and waits for a systemd boot
marker. This proves UEFI live boot to multi-user state, but not the complete
interactive installer path.

## Trust model

Each appliance has one trusted operator boundary. Multiple mutually untrusted
operators require separate appliances or VMs. Rootless containers, systemd
hardening, and firewall policy reduce impact, but they do not turn OpenClaw into
a hostile multi-tenant platform.

Physical console and boot-media control remain privileged. Secure boot signing,
measured boot, and automated full-disk encryption are not implemented in 0.1.0.
