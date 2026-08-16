# Security policy

OpenClaw OS is an appliance distribution that runs an AI agent gateway. Treat the Gateway, installed plugins, skills, model credentials, backups, workspaces, policy files, and sender allowlists as sensitive code and data.

## Supported branch

Security fixes are applied to `main` until tagged release branches are created.

## Reporting

Do not publish credentials, private configuration, backup archives, sender identities, or a working exploit in a public issue. Open a private GitHub security advisory for this repository or contact the repository owner directly.

Include the affected OpenClaw OS version, OpenClaw version, hardware or VM platform, active execution profile, host-root state, reproduction steps, impact, and any proposed fix.

## Trust boundaries

The appliance assumes one trusted operator per installation. It is not a hostile multi-tenant isolation boundary. Separate unrelated operators with separate VMs or separate physical hosts.

Physical console access is privileged. Anyone with console or boot-media control can reconfigure the appliance or bypass operating-system controls.

The default `locked` profile keeps OpenClaw tool execution in a rootless container with no sandbox network, a read-only container root, and all Linux capabilities dropped. This reduces impact. It does not make arbitrary model input, plugins, or OpenClaw vulnerabilities harmless.

The following are intentional operator-controlled trust changes:

- `connected` gives sandboxed tools outbound bridge networking.
- `developer` adds a writable container root.
- `power-user` runs as UID 0 inside the rootless container and restores the runtime default container capabilities.
- `host` disables the OpenClaw agent sandbox and runs tools as the Gateway service account.
- Elevated exec lets explicitly allowlisted senders request host execution under OpenClaw's remaining gates.
- `host-root` runs the Gateway as root and removes the base systemd privilege restrictions.

A report that only shows the documented authority of an intentionally enabled profile is not a vulnerability. A valid security issue includes behavior outside the selected policy, bypass of an acknowledgement or identity gate, escape from the documented boundary, unsafe rollback, credential exposure, unauthorized policy mutation, or failure to restore the hardened state.

Custom JSON5 policy patches are a supported power-user feature. The appliance validates schema and service health, but it cannot determine whether a writable bind, namespace join, GPU, environment value, or resource setting is safe for a particular deployment.

## Useful evidence

Include the output of these commands after removing credentials and personal sender identifiers:

```bash
sudo openclaw-appliance status
sudo openclaw-appliance policy status --json
sudo openclaw-appliance audit deep
systemctl cat openclaw.service
systemd-analyze security openclaw.service
```

Audit output is stored under `/var/log/openclaw/audits`. Backups and audit bundles can contain sensitive data. Do not attach them without reviewing and redacting them.
