import assert from "node:assert/strict";
import test from "node:test";
import type { AddressInfo } from "node:net";
import { createControllerServer } from "../../services/controller/src/server.ts";
import type { CompatibilityManifest } from "../../services/controller/src/compatibility.ts";

const compatibility: CompatibilityManifest = {
  schemaVersion: 1,
  openclawOsVersion: "0.1.0",
  controlPlanePhase: 1,
  gatewayProtocol: {
    minimum: 4,
    maximum: 4,
    requiredMethods: ["health"],
    operatorScopes: ["operator.read"],
  },
  testedOpenclawVersions: ["2026.6.34"],
};

const hostd = {
  async systemStatus() {
    return {
      hostname: "openclaw-os",
      architecture: "x64",
      kernelRelease: "test",
      uptimeSeconds: 1,
    };
  },
  async storageStatus() {
    return {
      path: "/var/lib/openclaw",
      blockSizeBytes: "4096",
      totalBytes: "1000",
      availableBytes: "500",
    };
  },
  async serviceStatus(unit: "openclaw.service" | "openclaw-hostd.service" | "openclaw-controller.service") {
    return {
      unit,
      loadState: "loaded",
      activeState: "active",
      subState: "running",
      unitFileState: "enabled",
      mainPid: 1,
      execMainStatus: 0,
    };
  },
};

async function startServer(gateway = {
  async snapshot() {
    return {
      available: true as const,
      protocol: 4,
      serverVersion: "2026.6.34",
      grantedScopes: ["operator.read"],
      advertisedMethodCount: 4,
      advertisedEventCount: 1,
      sequenceGapDetected: false,
      health: "healthy" as const,
    };
  },
}) {
  const server = createControllerServer({
    controllerVersion: "0.1.0-control-plane.1",
    compatibility,
    hostd,
    gateway,
    now: () => new Date("2026-08-15T20:00:00.000Z"),
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address() as AddressInfo;
  return { server, baseUrl: `http://127.0.0.1:${address.port}` };
}

test("controller exposes a sanitized read-only status surface", async (context) => {
  const { server, baseUrl } = await startServer();
  context.after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  const response = await fetch(`${baseUrl}/api/v1/status`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  const body = await response.json() as Record<string, unknown>;
  assert.equal(body.ok, true);
  assert.equal(body.state, "healthy");
  assert.equal((body.controller as Record<string, unknown>).mode, "read-only");
  assert.equal(JSON.stringify(body).includes("gateway-token"), false);

  const post = await fetch(`${baseUrl}/api/v1/status`, { method: "POST" });
  assert.equal(post.status, 405);
  assert.equal(post.headers.get("allow"), "GET, HEAD");
});

test("controller degrades without leaking dependency errors", async (context) => {
  const secret = "super-secret-gateway-token";
  const { server, baseUrl } = await startServer({
    async snapshot() {
      throw new Error(`connection failed with ${secret}`);
    },
  });
  context.after(() => new Promise<void>((resolve) => server.close(() => resolve())));

  const response = await fetch(`${baseUrl}/api/v1/status`);
  const bodyText = await response.text();
  assert.equal(response.status, 200);
  assert.equal(bodyText.includes(secret), false);
  const body = JSON.parse(bodyText) as Record<string, unknown>;
  assert.equal(body.ok, false);
  assert.equal(body.state, "degraded");
});
