# ADR 0001: OpenClaw OS control-plane boundary

Status: Accepted for phase 1

Date: 2026-08-15

## Context

OpenClaw OS 0.1.0 already manages the Debian image, OpenClaw release lifecycle,
systemd services, firewall policy, rootless Podman sandbox, backups, audits, and
recovery commands. Normal administration, however, is still centered on Bash
commands and a local `whiptail` console. The operating system does not yet have a
native, typed integration with the OpenClaw Gateway.

OpenClaw owns agents, channels, models, sessions, memory, skills, and its runtime
configuration. OpenClaw OS owns host policy, service lifecycle, storage,
network exposure, updates, backups, and recovery. A second copy of OpenClaw
configuration in the OS would create drift and is therefore rejected.

## Decision

OpenClaw OS will introduce a separate control plane around the Gateway.

Phase 1 contains two services:

- `openclaw-controller` is an unprivileged TypeScript service. It connects to the
  local Gateway through protocol version 4, requests only `operator.read`, and
  exposes a small read-only HTTP API on `127.0.0.1:9080`.
- `openclaw-hostd` is an unprivileged TypeScript service. It exposes a fixed,
  typed, read-only Unix-socket API for system, storage, and allowlisted systemd
  service status.

The controller and host service use separate Linux accounts and share only the
`openclaw-control` group needed for the Unix socket. Neither account can read
OpenClaw state files directly. The host service has no Linux capabilities, no
network address families other than `AF_UNIX`, and no arbitrary command
operation.

The existing Bash appliance remains the installer, rescue, and recovery plane.
It is not the controller API.

## Gateway integration

The pinned OpenClaw release, `2026.6.34`, contains the private Gateway protocol
schema package but not a published reusable Gateway client package. Phase 1
therefore carries a small compatibility client that copies no upstream source
and implements only the pinned protocol contract required for read-only status.

The client:

- connects only to an IP loopback WebSocket URL;
- negotiates only protocol version 4;
- waits for `connect.challenge` before sending `connect`;
- identifies as `gateway-client` in `backend` mode;
- requests role `operator` with only `operator.read`;
- fails closed if the negotiated scopes are broader;
- permits only an explicit read-only method registry;
- enforces pre-connect and negotiated frame limits;
- bounds pending requests and request timeouts;
- detects event sequence gaps;
- never exposes the Gateway credential through the HTTP API.

The compatibility manifest is stored at
`config/openclaw-compatibility.json`. Unsupported protocol versions fail closed.
Because phase 1 has no mutation API, an untested OpenClaw application version is
reported through compatibility metadata but cannot be modified through the
controller.

## Credential custody

Setup creates a random Gateway token at `/etc/openclaw/gateway-token` with
`root:root` ownership and mode `0600`. OpenClaw configuration stores an
environment SecretRef rather than the plaintext token.

`openclaw.service` and `openclaw-controller.service` each receive a private
runtime copy through `LoadCredential`. The browser never receives this token.
Direct appliance CLI calls load the credential only for commands that need to
resolve the SecretRef.

Phase 1 still uses the shared Gateway secret for the controller's loopback
connection. The client requests and accepts only `operator.read`, but possession
of the shared secret must still be treated as owner-level credential custody.
This is not yet a credential-level least-privilege boundary. A later phase must
provision a dedicated paired controller device identity and persist a device
token whose approved contract is limited to `operator.read`.

## Host API contract

The host Unix-socket protocol accepts exactly these operations:

- `system.status`
- `storage.status`
- `service.status`

`service.status` accepts only the following units:

- `openclaw.service`
- `openclaw-podman.service`
- `openclaw-hostd.service`
- `openclaw-controller.service`

Requests and responses use exact-field runtime validation and a 16 KiB frame
limit. `hostd` invokes `/usr/bin/systemctl show` directly with a fixed argument
shape. It does not invoke a shell and exposes no generic process execution.

Phase 1 deliberately keeps `hostd` unprivileged. Future mutating host operations
must be added individually, require a separate authorization and approval
contract, and must never introduce `Exec(command)` or an equivalent generic
root primitive.

## Controller HTTP surface

The controller binds only to `127.0.0.1:9080` and exposes:

- `GET /healthz`
- `GET /api/v1/status`
- `GET /api/v1/compatibility`

`HEAD` is also accepted. All other methods and paths are rejected. Request
bodies are rejected. Responses are non-cacheable and include restrictive
browser security headers. Dependency failures produce a degraded status without
returning raw internal errors.

This loopback API is not the final administrative web interface. A later web
console must add its own operator authentication before proxying or exposing
this API beyond loopback.

## Build and validation

The control-plane source has no runtime dependencies. The image build stages the
source into `/usr/lib/openclaw-os/control-plane` only after source validation.
The staged directory is removed from the working tree when the build exits.

Validation runs on the same pinned Node.js 24 release used by the appliance.
Tests cover protocol negotiation, scope escalation rejection, loopback URL
validation, typed host contracts, response correlation, socket replacement
safety, credential-file restrictions, controller sanitization, and degraded
operation. The control plane is included as a separate package in the generated
SPDX SBOM and build metadata.

## Consequences

OpenClaw remains authoritative for OpenClaw runtime state and schema. OpenClaw
OS gains a typed integration point without granting the controller filesystem
access to OpenClaw state or introducing a root web service.

Phase 1 does not provide a web console, configuration mutation, privileged host
operations, paired controller identity, persistent event projection, or replay
recovery. Those remain later control-plane phases.
