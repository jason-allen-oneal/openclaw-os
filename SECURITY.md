# Security policy

OpenClaw OS is an appliance distribution that runs an AI agent gateway. Treat
the Gateway, installed plugins, skills, model credentials, backups, and
workspaces as sensitive code and data.

## Supported branch

Security fixes are applied to `main` until tagged release branches are created.

## Reporting

Do not publish credentials, private configuration, backup archives, or a
working exploit in a public issue. Open a private GitHub security advisory for
this repository or contact the repository owner directly.

Include the affected OpenClaw OS version, OpenClaw version, hardware or VM
platform, reproduction steps, impact, and any proposed fix.

## Trust boundaries

The appliance assumes one trusted operator per installation. It is not a
hostile multi-tenant isolation boundary. Separate unrelated operators with
separate VMs or separate physical hosts.

Physical console access is privileged. Anyone with console or boot-media
control can reconfigure the appliance or bypass operating-system controls.
