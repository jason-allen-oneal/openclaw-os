# OpenClaw execution policies

OpenClaw OS separates four controls that are often confused:

1. OpenClaw tool allow and deny policy.
2. OpenClaw sandbox configuration.
3. OpenClaw elevated-exec identity and approval policy.
4. The systemd service boundary around the Gateway.

Changing one control does not automatically bypass the others.

## Managed profiles

### locked

The default profile. All agent sessions use rootless Podman, sandbox networking
is disabled, the container root is read-only, and all Linux capabilities are
dropped. The agent workspace remains writable.

```bash
sudo openclaw-appliance policy apply locked
```

### connected

Keeps the locked container restrictions but enables rootless bridge networking.
This allows tools to reach external services permitted by host routing and
firewall policy.

```bash
sudo openclaw-appliance policy apply connected --acknowledge-risk
```

### developer

Enables bridge networking and a writable container root. Linux capabilities are
still dropped, and execution remains inside rootless Podman.

```bash
sudo openclaw-appliance policy apply developer --acknowledge-risk
```

### power-user

Runs tools as UID 0 inside the rootless user namespace, uses a writable
container root, enables bridge networking, and restores the container runtime's
default capability set.

UID 0 inside a rootless user namespace is not host root. It is still a material
increase in authority inside the sandbox.

```bash
sudo openclaw-appliance policy apply power-user --acknowledge-risk
```

### host

Disables the OpenClaw agent sandbox. Tool execution occurs directly in the
Gateway service context. The systemd unit still runs as the unprivileged
`openclaw` account and retains its filesystem, capability, and kernel hardening.

```bash
sudo openclaw-appliance policy apply host --acknowledge-risk
```

OpenClaw OS does not provide a managed root-Gateway mode in this release.

## Transaction behavior

A managed profile change:

1. Refuses missing, empty, oversized, or symlinked patch files.
2. Runs `openclaw config patch --dry-run`.
3. Saves the active configuration with its ownership and mode.
4. Stops the Gateway only if it was active.
5. Applies and validates the candidate configuration.
6. Recreates sandbox containers.
7. Restarts and health-checks the Gateway only if it was previously active.
8. Restores the prior configuration and service state on failure.
9. Records policy provenance under `/etc/openclaw/policy-state.json`.

The state file records the last appliance-managed profile. Direct OpenClaw
configuration edits can create drift, so `policy status` also displays effective
settings from the active configuration.

## Elevated execution

OpenClaw elevated mode permits a sandboxed session to request execution outside
the sandbox. OpenClaw OS requires an exact provider and sender identity:

```bash
sudo openclaw-appliance policy elevated enable \
  discord user-id-123 --acknowledge-risk
```

Disable and clear the global elevated allowlist:

```bash
sudo openclaw-appliance policy elevated disable
```

Elevated mode does not override a denied `exec` tool, OpenClaw approval policy,
or the systemd service boundary. On OpenClaw OS it runs as the `openclaw` service
account, not as root.

Only identities you fully control should be allowlisted. Display names are weak
identifiers. Prefer stable channel-specific IDs.

## Custom patches

Power users may apply a JSON5 OpenClaw configuration patch through the same
transaction:

```bash
sudo openclaw-appliance policy patch ./custom-policy.json5 --acknowledge-risk
```

The appliance validates the OpenClaw schema and post-change health. It cannot
determine whether a custom bind mount, environment variable, DNS server, GPU,
namespace join, resource setting, or tool permission is appropriate for a
particular deployment.

Custom patches are limited to 1 MiB and must be regular, non-symlinked files.

## Inspection and recovery

```bash
sudo openclaw-appliance policy list
sudo openclaw-appliance policy status
sudo openclaw-appliance policy status --json
sudo openclaw-appliance audit deep
systemctl cat openclaw.service
systemd-analyze security openclaw.service
```

Return to the hardened baseline with:

```bash
sudo openclaw-appliance policy apply locked
```
