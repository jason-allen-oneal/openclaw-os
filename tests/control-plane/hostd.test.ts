import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { APPLIANCE_API_VERSION } from "../../packages/appliance-contracts/src/index.ts";
import { HostdClient } from "../../services/controller/src/hostd-client.ts";
import {
  HostdServerError,
  createHostdServer,
  type HostdOperationHandlers,
} from "../../services/hostd/src/server.ts";

const handlers: HostdOperationHandlers = {
  async systemStatus() {
    return {
      hostname: "openclaw-os",
      architecture: "x64",
      kernelRelease: "test-kernel",
      uptimeSeconds: 42,
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
  async serviceStatus(unit) {
    return {
      unit,
      loadState: "loaded",
      activeState: "active",
      subState: "running",
      unitFileState: "enabled",
      mainPid: 123,
      execMainStatus: 0,
    };
  },
};

async function rawRequest(socketPath: string, request: unknown): Promise<Record<string, unknown>> {
  return await new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let buffered = "";
    socket.once("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline !== -1) {
        socket.destroy();
        resolve(JSON.parse(buffered.slice(0, newline)) as Record<string, unknown>);
      }
    });
    socket.once("error", reject);
  });
}

test("hostd serves only the typed read-only contract", async (context) => {
  const directory = await fs.mkdtemp(join(tmpdir(), "openclaw-hostd-test-"));
  const socketPath = join(directory, "hostd.sock");
  const server = await createHostdServer({ socketPath, handlers });
  context.after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(directory, { recursive: true, force: true });
  });

  const client = new HostdClient({ socketPath });
  assert.equal((await client.systemStatus()).hostname, "openclaw-os");
  assert.equal((await client.storageStatus()).availableBytes, "500");
  assert.equal((await client.serviceStatus("openclaw.service")).activeState, "active");

  const rejected = await rawRequest(socketPath, {
    version: APPLIANCE_API_VERSION,
    id: "bad-operation",
    operation: "exec",
    params: { command: "id" },
  });
  assert.equal(rejected.ok, false);
  assert.equal((rejected.error as Record<string, unknown>).code, "UNSUPPORTED_OPERATION");
});

test("hostd refuses to replace a symlink at its socket path", async () => {
  const directory = await fs.mkdtemp(join(tmpdir(), "openclaw-hostd-symlink-"));
  const socketPath = join(directory, "hostd.sock");
  await fs.symlink(join(directory, "target"), socketPath);
  await assert.rejects(
    createHostdServer({ socketPath, handlers }),
    (error: unknown) => error instanceof HostdServerError,
  );
  await fs.rm(directory, { recursive: true, force: true });
});

test("hostd refuses to unlink an active socket", async (context) => {
  const directory = await fs.mkdtemp(join(tmpdir(), "openclaw-hostd-active-"));
  const socketPath = join(directory, "hostd.sock");
  const server = await createHostdServer({ socketPath, handlers });
  context.after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await fs.rm(directory, { recursive: true, force: true });
  });

  await assert.rejects(
    createHostdServer({ socketPath, handlers }),
    (error: unknown) => error instanceof HostdServerError,
  );
});
