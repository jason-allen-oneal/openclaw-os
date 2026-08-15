import {
  OpenClawGatewayClient,
  type GatewayConnectionInfo,
} from "../../../packages/gateway-client/src/index.ts";

export type SafeGatewaySnapshot = {
  available: true;
  protocol: number;
  serverVersion: string;
  grantedScopes: string[];
  advertisedMethodCount: number;
  advertisedEventCount: number;
  sequenceGapDetected: boolean;
  health: "healthy" | "degraded" | "unknown";
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function summarizeGatewayHealth(payload: unknown): SafeGatewaySnapshot["health"] {
  if (!isRecord(payload)) {
    return "unknown";
  }
  if (payload.ok === true || payload.healthy === true || payload.status === "ok") {
    return "healthy";
  }
  if (payload.ok === false || payload.healthy === false || payload.degraded === true) {
    return "degraded";
  }
  return "unknown";
}

function createSafeSnapshot(
  connection: GatewayConnectionInfo,
  healthPayload: unknown,
): SafeGatewaySnapshot {
  return {
    available: true,
    protocol: connection.protocol,
    serverVersion: connection.serverVersion,
    grantedScopes: [...connection.scopes],
    advertisedMethodCount: connection.methods.length,
    advertisedEventCount: connection.events.length,
    sequenceGapDetected: connection.sequenceGapDetected,
    health: summarizeGatewayHealth(healthPayload),
  };
}

export class OpenClawGatewayStatusProvider {
  readonly #client: OpenClawGatewayClient;

  constructor(client: OpenClawGatewayClient) {
    this.#client = client;
  }

  async snapshot(): Promise<SafeGatewaySnapshot> {
    try {
      await this.#client.connect();
      const health = await this.#client.request("health", {});
      return createSafeSnapshot(this.#client.getConnectionInfo(), health);
    } catch {
      this.#client.close();
      throw new Error("gateway status is unavailable");
    }
  }

  close(): void {
    this.#client.close();
  }
}
