import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type {
  AllowedServiceUnit,
  ServiceStatus,
  StorageStatus,
  SystemStatus,
} from "../../../packages/appliance-contracts/src/index.ts";
import type { CompatibilityManifest } from "./compatibility.ts";
import type { SafeGatewaySnapshot } from "./gateway-status.ts";

const STATUS_PATH = "/api/v1/status";
const COMPATIBILITY_PATH = "/api/v1/compatibility";
const HEALTH_PATH = "/healthz";
const MAX_CONCURRENT_STATUS_REQUESTS = 8;

export type ControllerHostdClient = {
  systemStatus(): Promise<SystemStatus>;
  storageStatus(): Promise<StorageStatus>;
  serviceStatus(unit: AllowedServiceUnit): Promise<ServiceStatus>;
};

export type ControllerGatewayProvider = {
  snapshot(): Promise<SafeGatewaySnapshot>;
};

export type ControllerServerOptions = {
  controllerVersion: string;
  compatibility: CompatibilityManifest;
  hostd: ControllerHostdClient;
  gateway: ControllerGatewayProvider;
  now?: () => Date;
  maximumConcurrentStatusRequests?: number;
};

type UnavailableComponent = {
  available: false;
  state: "unavailable";
};

function setSecurityHeaders(response: ServerResponse, requestId: string): void {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
  response.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin");
  response.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Frame-Options", "DENY");
  response.setHeader("X-Request-Id", requestId);
}

function writeJson(
  response: ServerResponse,
  statusCode: number,
  requestId: string,
  value: unknown,
  extraHeaders: Record<string, string> = {},
): void {
  const body = JSON.stringify(value);
  response.statusCode = statusCode;
  setSecurityHeaders(response, requestId);
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Content-Length", Buffer.byteLength(body, "utf8"));
  for (const [name, headerValue] of Object.entries(extraHeaders)) {
    response.setHeader(name, headerValue);
  }
  response.end(body);
}

function requestHasBody(request: IncomingMessage): boolean {
  const contentLength = request.headers["content-length"];
  return (
    request.headers["transfer-encoding"] !== undefined ||
    (typeof contentLength === "string" && contentLength !== "0")
  );
}

function unavailable(): UnavailableComponent {
  return { available: false, state: "unavailable" };
}

async function collectHostSnapshot(hostd: ControllerHostdClient): Promise<
  | {
      available: true;
      system: SystemStatus;
      storage: StorageStatus;
      services: ServiceStatus[];
    }
  | UnavailableComponent
> {
  try {
    const [system, storage, gatewayService, hostdService, controllerService] = await Promise.all([
      hostd.systemStatus(),
      hostd.storageStatus(),
      hostd.serviceStatus("openclaw.service"),
      hostd.serviceStatus("openclaw-hostd.service"),
      hostd.serviceStatus("openclaw-controller.service"),
    ]);
    return {
      available: true,
      system,
      storage,
      services: [gatewayService, hostdService, controllerService],
    };
  } catch {
    return unavailable();
  }
}

export function createControllerServer(options: ControllerServerOptions): Server {
  const now = options.now ?? (() => new Date());
  const maximumConcurrentStatusRequests =
    options.maximumConcurrentStatusRequests ?? MAX_CONCURRENT_STATUS_REQUESTS;
  let activeStatusRequests = 0;

  const server = createServer((request, response) => {
    const requestId = randomUUID();
    const method = request.method ?? "GET";
    let path: string;
    try {
      path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    } catch {
      writeJson(response, 400, requestId, { ok: false, error: "invalid_request" });
      return;
    }

    if (method !== "GET" && method !== "HEAD") {
      writeJson(
        response,
        405,
        requestId,
        { ok: false, error: "method_not_allowed" },
        { Allow: "GET, HEAD" },
      );
      return;
    }
    if (requestHasBody(request)) {
      writeJson(response, 400, requestId, { ok: false, error: "request_body_not_allowed" });
      return;
    }

    if (path === HEALTH_PATH) {
      const payload = {
        ok: true,
        service: "openclaw-controller",
        version: options.controllerVersion,
      };
      if (method === "HEAD") {
        const body = JSON.stringify(payload);
        response.statusCode = 200;
        setSecurityHeaders(response, requestId);
        response.setHeader("Content-Type", "application/json; charset=utf-8");
        response.setHeader("Content-Length", Buffer.byteLength(body, "utf8"));
        response.end();
      } else {
        writeJson(response, 200, requestId, payload);
      }
      return;
    }

    if (path === COMPATIBILITY_PATH) {
      if (method === "HEAD") {
        const body = JSON.stringify(options.compatibility);
        response.statusCode = 200;
        setSecurityHeaders(response, requestId);
        response.setHeader("Content-Type", "application/json; charset=utf-8");
        response.setHeader("Content-Length", Buffer.byteLength(body, "utf8"));
        response.end();
      } else {
        writeJson(response, 200, requestId, options.compatibility);
      }
      return;
    }

    if (path !== STATUS_PATH) {
      writeJson(response, 404, requestId, { ok: false, error: "not_found" });
      return;
    }
    if (activeStatusRequests >= maximumConcurrentStatusRequests) {
      writeJson(response, 503, requestId, { ok: false, error: "controller_busy" });
      return;
    }

    activeStatusRequests += 1;
    void Promise.all([
      collectHostSnapshot(options.hostd),
      options.gateway.snapshot().catch(() => unavailable()),
    ])
      .then(([host, gateway]) => {
        const ok = host.available && gateway.available;
        const payload = {
          ok,
          state: ok ? "healthy" : "degraded",
          generatedAt: now().toISOString(),
          controller: {
            version: options.controllerVersion,
            mode: "read-only",
          },
          compatibility: {
            openclawOsVersion: options.compatibility.openclawOsVersion,
            controlPlanePhase: options.compatibility.controlPlanePhase,
            gatewayProtocol: options.compatibility.gatewayProtocol,
          },
          gateway,
          host,
        };
        if (method === "HEAD") {
          const body = JSON.stringify(payload);
          response.statusCode = 200;
          setSecurityHeaders(response, requestId);
          response.setHeader("Content-Type", "application/json; charset=utf-8");
          response.setHeader("Content-Length", Buffer.byteLength(body, "utf8"));
          response.end();
        } else {
          writeJson(response, 200, requestId, payload);
        }
      })
      .catch(() => {
        writeJson(response, 500, requestId, { ok: false, error: "status_collection_failed" });
      })
      .finally(() => {
        activeStatusRequests -= 1;
      });
  });

  server.requestTimeout = 5_000;
  server.headersTimeout = 6_000;
  server.keepAliveTimeout = 5_000;
  server.maxRequestsPerSocket = 100;
  return server;
}
