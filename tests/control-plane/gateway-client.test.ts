import assert from "node:assert/strict";
import test from "node:test";
import {
  GatewayProtocolError,
  OpenClawGatewayClient,
  assertLoopbackGatewayUrl,
  type GatewaySocket,
  type GatewaySocketFactory,
} from "../../packages/gateway-client/src/index.ts";

type Listener = (event: { data?: unknown }) => void;

class FakeGatewaySocket implements GatewaySocket {
  readyState = 1;
  readonly listeners = new Map<string, Set<Listener>>();
  readonly sent: unknown[] = [];
  readonly scopes: string[];

  constructor(scopes = ["operator.read"]) {
    this.scopes = scopes;
    queueMicrotask(() => {
      this.emit("message", {
        data: JSON.stringify({
          type: "event",
          event: "connect.challenge",
          payload: { nonce: "nonce", ts: Date.now() },
        }),
      });
    });
  }

  addEventListener(type: string, listener: Listener): void {
    const set = this.listeners.get(type) ?? new Set<Listener>();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: Listener): void {
    this.listeners.get(type)?.delete(listener);
  }

  send(data: string): void {
    const frame = JSON.parse(data) as Record<string, unknown>;
    this.sent.push(frame);
    if (frame.method === "connect") {
      const params = frame.params as Record<string, unknown>;
      assert.equal(params.minProtocol, 4);
      assert.equal(params.maxProtocol, 4);
      assert.equal(params.role, "operator");
      assert.deepEqual(params.scopes, ["operator.read"]);
      assert.equal((params.client as Record<string, unknown>).id, "gateway-client");
      assert.equal((params.client as Record<string, unknown>).mode, "backend");
      queueMicrotask(() => {
        this.emit("message", {
          data: JSON.stringify({
            type: "res",
            id: frame.id,
            ok: true,
            payload: {
              type: "hello-ok",
              protocol: 4,
              server: { version: "2026.6.34", connId: "connection-1" },
              features: {
                methods: ["health", "status", "channels.status", "models.list"],
                events: ["heartbeat"],
              },
              snapshot: {},
              auth: { role: "operator", scopes: this.scopes },
              policy: {
                maxPayload: 26214400,
                maxBufferedBytes: 52428800,
                tickIntervalMs: 15000,
              },
            },
          }),
        });
      });
      return;
    }
    if (frame.method === "health") {
      queueMicrotask(() => {
        this.emit("message", {
          data: JSON.stringify({ type: "res", id: frame.id, ok: true, payload: { ok: true } }),
        });
      });
    }
  }

  close(): void {
    this.readyState = 3;
  }

  emit(type: string, event: { data?: unknown }): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }
}

function factoryWith(socket: FakeGatewaySocket): GatewaySocketFactory {
  return () => socket;
}

test("gateway client negotiates protocol 4 with operator.read only", async () => {
  const socket = new FakeGatewaySocket();
  const client = new OpenClawGatewayClient({
    url: "ws://127.0.0.1:18789",
    token: "a".repeat(64),
    controllerVersion: "0.1.0-control-plane.1",
    socketFactory: factoryWith(socket),
  });

  const connection = await client.connect();
  assert.equal(connection.protocol, 4);
  assert.equal(connection.serverVersion, "2026.6.34");
  assert.deepEqual(connection.scopes, ["operator.read"]);
  assert.deepEqual(await client.request("health", {}), { ok: true });
  assert.equal(JSON.stringify(connection).includes("a".repeat(64)), false);
  client.close();
});

test("gateway client rejects methods outside the read-only allowlist", async () => {
  const client = new OpenClawGatewayClient({
    url: "ws://127.0.0.1:18789",
    token: "b".repeat(64),
    controllerVersion: "test",
    socketFactory: factoryWith(new FakeGatewaySocket()),
  });
  await assert.rejects(
    client.request("config.set" as never, {}),
    (error: unknown) =>
      error instanceof GatewayProtocolError && error.code === "METHOD_NOT_ALLOWED",
  );
});

test("gateway client fails closed if the Gateway grants broader scopes", async () => {
  const client = new OpenClawGatewayClient({
    url: "ws://127.0.0.1:18789",
    token: "c".repeat(64),
    controllerVersion: "test",
    socketFactory: factoryWith(new FakeGatewaySocket(["operator.read", "operator.write"])),
    connectBudgetMs: 500,
  });
  await assert.rejects(
    client.connect(),
    (error: unknown) =>
      error instanceof GatewayProtocolError && error.code === "SCOPE_ESCALATION",
  );
});

test("gateway client rejects non-loopback targets", () => {
  assert.throws(
    () => assertLoopbackGatewayUrl("wss://gateway.example.com:18789"),
    (error: unknown) =>
      error instanceof GatewayProtocolError && error.code === "NON_LOOPBACK_GATEWAY_URL",
  );
});
