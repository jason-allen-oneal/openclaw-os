# OpenClaw OS execution profiles

The appliance starts with `locked`.

```text
locked      Rootless sandbox, no network, read-only root, capabilities dropped
connected   locked plus outbound bridge networking
developer   connected plus writable container root
power-user  rootless container UID 0, writable root, runtime default capabilities
host        sandbox disabled, execution as the unprivileged openclaw service user
```

Inspect and change policy:

```bash
sudo openclaw-appliance policy status
sudo openclaw-appliance policy list
sudo openclaw-appliance policy apply <profile> --acknowledge-risk
sudo openclaw-appliance policy apply locked
```

Profiles other than `locked` weaken isolation. `host` does not run the Gateway as
root. See the repository `docs/POLICIES.md` for elevated sender controls, custom
patches, transaction rollback, and the full trust model.
