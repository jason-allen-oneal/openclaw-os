# OpenClaw OS architecture

## Design goal

OpenClaw OS is an appliance, not a general desktop distribution. Debian owns the kernel, package manager, installer, hardware support, and base security updates. This repository owns the image profile and the OpenClaw-specific runtime, policy, services, console, backups, audits, and release transaction.

The build is independent of any local OpenClaw checkout. Upstream Node.js and OpenClaw artifacts are fetched from their release endpoints and validated from pinned metadata.

## Filesystem layout

```text
/etc/openclaw/                    Appliance policy, policy state, and firewall allowlists
/etc/systemd/system/              Optional managed host-root service drop-in
/opt/node/releases/<version>/    Immutable Node.js runtimes
/opt/node/current                Active Node.js symlink
/opt/openclaw/releases/<version> Immutable npm global prefixes
/opt/openclaw/current            Active OpenClaw symlink
/var/lib/openclaw/state/         OpenClaw state and active config
/var/lib/openclaw/backups/       Verified local backup archives
/var/lib/openclaw/containers/    Rootless Podman storage
/srv/openclaw/workspaces/        Agent workspaces
/var/log/openclaw/audits/        OpenClaw and appliance-policy audit output
/run/openclaw/                   Podman API socket and runtime data
/usr/share/openclaw-os/          Image metadata, defaults, policies, sandbox source, SBOM
```

## Default service boundary

`openclaw.service` runs as the `openclaw` account by default. It has no Linux capabilities, uses `NoNewPrivileges`, protects the operating-system tree, and receives write access only to state, workspaces, logs, and runtime directories. It is conditional on a real, non-symlinked OpenClaw configuration file, so it cannot start before onboarding.

OpenClaw's bundled sandbox backend invokes a command named `docker`. OpenClaw OS provides that command as a compatibility wrapper around the remote Podman client. The client connects to `openclaw-podman.service`, a rootless Podman API service owned by the same unprivileged account. User-namespace setup therefore occurs outside the more restrictive Gateway service without exposing a root-owned Docker socket.

## Managed privilege boundaries

Privilege is divided across four independent controls:

1. OpenClaw tool policy.
2. OpenClaw sandbox configuration.
3. Elevated-exec identity and approval policy.
4. The Gateway systemd service boundary.

The appliance ships five OpenClaw execution profiles:

```text
locked
connected
developer
power-user
host
```

The first four keep the Gateway service on the host and place tool execution in rootless Podman with progressively weaker container restrictions. `host` disables the OpenClaw agent sandbox, but host commands still run as the `openclaw` service account unless the separate host-root override is enabled.

Every managed profile disables elevated exec and clears the global elevated sender allowlist. Elevated access is configured separately with an exact provider and sender identity.

The host-root override is a managed systemd drop-in. It changes the Gateway service user to root and removes the base unit restrictions that would otherwise block meaningful root authority. The override has a distinct acknowledgement flag, its own state file, unit validation, health checking, rollback, and unmanaged-file refusal behavior.

This separation prevents a networked development sandbox from silently becoming host execution, and prevents host execution from silently becoming root.

## Configuration ownership

The active config is a regular file at:

```text
/var/lib/openclaw/state/openclaw.json
```

The environment sets `OPENCLAW_SERVICE_REPAIR_POLICY=external`, which prevents OpenClaw repair operations from replacing the appliance-managed system service with a user service.

Onboarding creates the initial configuration. The appliance applies its base safety patch and the `locked` managed profile through `openclaw config patch`, then asks OpenClaw to validate the result. OpenClaw remains the authority for its own configuration schema.

The base safety patch disables mDNS discovery, keeps the Gateway on loopback, selects extended-stable, and disables OpenClaw-managed background code updates. The profile patch owns sandbox and elevated-exec defaults.

The last managed profile is recorded at:

```text
/etc/openclaw/policy-state.json
```

This is provenance, not a drift guarantee. Effective status is read from the active OpenClaw configuration.

## Policy transaction

Managed profiles, elevated allowlist changes, and operator-supplied JSON5 patches use a common transaction:

1. Reject missing, empty, oversized, or symlinked patch files.
2. Run `openclaw config patch --dry-run`.
3. Copy the active config while preserving ownership and mode.
4. Stop the Gateway only if it is active.
5. Apply and validate the candidate config.
6. Reset sandbox containers so the next execution uses the new policy.
7. Restart the Gateway only if it was previously active.
8. Require a healthy Gateway.
9. Restore the previous config and service state on failure.

Custom patches are allowed because OpenClaw OS is a single-operator appliance. The transaction validates schema and service health. It cannot validate whether the operator intended to grant a dangerous bind, GPU, namespace join, or resource limit.

## Host-root transaction

The managed host-root template is stored under:

```text
/usr/share/openclaw-os/policies/openclaw-host-root.conf
```

Enablement writes:

```text
/etc/systemd/system/openclaw.service.d/90-openclaw-host-root.conf
/etc/openclaw/host-root-state.json
```

The state file records the installed drop-in SHA-256. This lets a later appliance version recognize and remove a previously managed template without treating normal template evolution as an unmanaged modification.

Enable and disable operations:

1. Refuse symlinked or unmanaged targets.
2. Install or remove the drop-in atomically.
3. Run `systemd-analyze verify` when enabling.
4. Reload systemd.
5. Restart only an already-active Gateway.
6. Require Gateway health.
7. Restore the prior drop-in and state on failure.

## Network boundary

The base nftables policy drops inbound and forwarded traffic and permits outbound traffic. Loopback, established traffic, ICMP, ICMPv6, and DHCP replies are allowed.

Two TCP allowlists are maintained:

- `allowed_tcp_ports` permits an operator-selected port from any source.
- `allowed_lan_tcp_ports` permits a port only from RFC1918, carrier-grade NAT or tailnet, IPv4 link-local, IPv6 ULA, and IPv6 link-local sources.

Authenticated Gateway LAN exposure uses the second list. Key-only SSH uses the first list when the operator explicitly enables it.

The `connected`, `developer`, and `power-user` profiles give rootless sandbox containers bridge networking. This is outbound sandbox connectivity, not inbound Gateway exposure.

## Artifact trust path

The image pins each Node.js archive by SHA-256. OpenClaw installation requires:

- An exact version and exact npm registry tarball URL.
- A SHA-512 SRI from pinned or resolved registry metadata.
- Non-empty npm registry signature metadata.
- The same SRI in the corresponding published GitHub release record.
- The expected release commit for the version embedded in the OS image.
- A package archive whose `package.json` reports the expected version.
- A staged `openclaw --version` result before activation.

npm installation runs with isolated user, global, cache, and home paths so host npm configuration does not influence the transaction.

## Update transaction

Core updates are installed into a new versioned prefix. Existing state is backed up first. Configuration is validated with the candidate binary before the active code symlink changes. After activation, systemd restarts the Gateway and the appliance checks the health RPC. A failed activation restores the previous code symlink and attempts to restart the prior release.

The appliance retains the active release plus the newest configured number of fallback releases. State rollback is deliberately separate from code rollback.

## Control-plane boundary

`openclaw-controller` is loopback-only. `openclaw-hostd` is reachable only over a bounded Unix socket. Phase 1 exposes status and compatibility information, not arbitrary command execution or service mutation.

The root-only appliance CLI remains the write boundary for execution policy, networking, updates, backups, SSH, and host-root mode. Moving those operations into the control plane requires an explicit authorization, confirmation, audit, and rollback design.

## Build and test boundary

GitHub Actions runs the image build in a privileged, digest-pinned Debian 13 container so Debian's current `live-build` is used instead of the older Ubuntu package. Actions are pinned by full commit SHA.

Static validation includes shell syntax, ShellCheck, release pin shape, action pins, service hardening, credential-pattern checks, firewall rendering, and appliance unit tests. Policy tests exercise profile discovery, policy provenance, successful transactions, config rollback, risk acknowledgements, elevated patch rendering, managed host-root installation and removal, and status JSON.

The image build emits an SPDX 2.3 SBOM from the final chroot package database and the separately installed Node.js and OpenClaw runtimes. After the ISO is built, a UEFI QEMU smoke test boots the live environment and waits for a systemd boot marker. This proves UEFI live boot to multi-user state, but not the complete interactive installer path.

## Trust model

Each appliance has one trusted operator boundary. Multiple mutually untrusted operators require separate appliances or VMs. Rootless containers, systemd hardening, identity allowlists, and firewall policy reduce impact, but they do not turn OpenClaw into a hostile multi-tenant platform.

The `host-root` override deliberately removes the operating-system privilege boundary for the Gateway. In that state, model-directed host execution, OpenClaw core, plugins, channel adapters, and any Gateway compromise have root authority.

Physical console and boot-media control remain privileged. Secure boot signing, measured boot, and automated full-disk encryption are not implemented in 0.1.0.
