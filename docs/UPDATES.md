# OpenClaw update and rollback runbook

OpenClaw OS separates Debian base-system maintenance from OpenClaw application
updates. Debian security packages use unattended-upgrades. OpenClaw application
code uses the appliance release transaction described here.

OpenClaw's own startup update check and background updater are disabled. Do not
re-enable them on an appliance unless you are intentionally bypassing the
appliance's verification, compatibility, staging, and rollback controls.

## Compatibility policy

Each OpenClaw OS image includes a compatibility contract at:

```text
/usr/lib/openclaw-os/control-plane/config/openclaw-compatibility.json
```

The source of that contract is `config/openclaw-compatibility.json`. Its
`testedOpenclawVersions` list contains exact OpenClaw versions tested with the
current OpenClaw OS release and control plane.

The default appliance setting is:

```text
OPENCLAW_UPDATE_POLICY=tested-only
```

This blocks staging and activation of versions outside the tested list. It does
not prevent an operator from checking release metadata.

## Normal tested update

First inspect the current update state:

```bash
sudo openclaw-appliance update status
```

Resolve and verify the configured channel without changing the appliance:

```bash
sudo openclaw-appliance update check extended-stable
```

The check reports the exact resolved version, active version, compatibility
result, policy, and whether activation is allowed. Copy the exact resolved
version from that output.

Stage the exact version:

```bash
sudo openclaw-appliance update stage <exact-version>
```

Staging performs these operations:

1. Resolve npm metadata for the exact version.
2. Require npm registry signature metadata.
3. Cross-check npm SRI with the matching GitHub release record.
4. Download and verify the package archive.
5. Install it into `/opt/openclaw/releases/<version>`.
6. Validate the active configuration with the candidate binary.
7. Record root-owned pending metadata under `/var/lib/openclaw/update-state`.

Staging does not change `/opt/openclaw/current`, stop the Gateway, or start the
candidate.

Review the pending candidate:

```bash
sudo openclaw-appliance update status
sudo openclaw-appliance releases
```

Apply the recorded exact candidate:

```bash
sudo openclaw-appliance update apply
```

Applying performs these operations:

1. Re-read and validate the pending metadata.
2. Re-check compatibility against the current OS contract.
3. Re-validate the active configuration with the candidate binary.
4. Create and verify an OpenClaw backup when configured state exists.
5. Record whether `openclaw.service` is active.
6. Stop the Gateway only when it was active.
7. Atomically switch `/opt/openclaw/current`.
8. Validate the configuration through the active symlink.
9. Restart and health-check the Gateway only when it was previously active.
10. Restore the previous code symlink and service state on failure.
11. Clear pending metadata and prune old code releases after success.

A Gateway that was intentionally stopped remains stopped after a successful
update or rollback.

## Cancel a staged activation

Cancel the pending activation without deleting the installed code prefix:

```bash
sudo openclaw-appliance update cancel
```

The inactive code release remains available until normal release pruning
removes it. This avoids deleting a candidate while another operator may still be
inspecting it.

## Untested exact release

An unlisted OpenClaw release is not covered by the OpenClaw OS compatibility
contract. Checking it is allowed:

```bash
sudo openclaw-appliance update check <exact-version>
```

Staging and applying it require the exact version and an explicit acknowledgement
at both steps:

```bash
sudo openclaw-appliance update stage <exact-version> --allow-untested
sudo openclaw-appliance update apply <exact-version> --allow-untested
```

The acknowledgement cannot be used with `latest`, `extended-stable`, or another
moving npm tag. This prevents a tag from resolving to a different release
between review and activation.

A power user can persist the exact-version exception in
`/etc/openclaw/appliance.conf`:

```text
OPENCLAW_UPDATE_POLICY=allow-untested-exact
```

The exact-version requirement still applies. Persistent policy does not permit
an untested moving tag.

## Immediate compatibility syntax

The original syntax remains available:

```bash
sudo openclaw-appliance update <version-or-tag>
```

It resolves, stages, backs up, and applies in one command. It still enforces the
compatibility policy and rollback checks. The separate check, stage, and apply
flow is preferred because it provides a review boundary and records an exact
candidate before activation.

## Code rollback

List installed releases:

```bash
sudo openclaw-appliance releases
```

Roll back to the newest inactive release:

```bash
sudo openclaw-appliance rollback
```

Or name an installed release:

```bash
sudo openclaw-appliance rollback <exact-version>
```

Rollback validates the target against the active configuration, preserves the
prior Gateway service state, switches the symlink, and health-checks the target
when the Gateway was running.

## State rollback limitation

Code rollback and state rollback are intentionally separate. A newly started
OpenClaw release may perform a state or configuration migration before failing
its health check. OpenClaw OS creates a verified backup immediately before
activation, but it does not automatically restore that backup.

Automatic state restore could rewind credentials, channel ratchets, approvals,
delivery queues, conversations, and workspaces. Review the failure and backup
contents before restoring state. Treat untested releases as potentially
state-incompatible even when code rollback succeeds.

## Recovery checks

After an update or rollback, inspect:

```bash
sudo openclaw-appliance status
sudo openclaw-appliance update status
sudo openclaw-appliance releases
sudo openclaw-appliance logs 250
sudo openclaw-appliance audit deep
```

Do not delete the previous code release or the pre-activation backup until the
new release has operated normally through the deployment's expected channels,
plugins, tools, and scheduled work.
