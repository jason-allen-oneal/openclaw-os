import { randomUUID } from "node:crypto";

export const OPENCLAW_GATEWAY_PROTOCOL = 4;
export const OPENCLAW_OPERATOR_SCOPES = ["operator.read"] as const;
export const GATEWAY_PRECONNECT_MAX_BYTES = 64 * 1024;
export const GATEWAY_HARD_MAX_BYTES = 8 * 1024 * 1024;

export const READ_ONLY_GATEWAY_METHODS = [
  "health",
  "status",
  "channels.status",
  "models.list",
] as const;

export type ReadOnlyGatewayMethod = (typeof READ_ONLY_GATEWAY_METHODS)[number];

type SocketEvent = { data?: unknown };
type SocketListener = (event: SocketEvent) => void;

export type GatewaySocket = {
  readonly readyState: number;
  addEventListener(type: "open" | "message" | "error" | "close", listener: SocketListener): void;
  removeEventListener(type: "open" | "message" | "error" | "close", listener: SocketListener): void;
  send(data: string): void;
  close(code?: number, reason?: string): void;
};

export type GatewaySocketFactory = (url: string) => GatewaySocket;

export type GatewayConnectionInfo = {
  protocol: number;
  serverVersion: string;
  connectionId: string;
  methods: readonly string[];
  events: readonly string[];
  scopes: readonly string[];
  sequenceGapDetected: boolean;
};

type GatewayResponseError = {
  code?: unknown;
  message?: unknown;
  details?: unknown;
  retryable?: unknown;
  retryAfterMs?: unknown;
};

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

export class GatewayProtocolError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly retryAfterMs: number | null;

  constructor(
    message: string,
    options: {
      code?: string;
      retryable?: boolean;
      retryAfterMs?: number | null;
    } = {},
  ) {
    super(message);
    this.name = "GatewayProtocolError";
    this.code = options.code ?? "GATEWAY_PROTOCOL_ERROR";
    this.retryable = options.retryable ?? false;
    this.retryAfterMs = options.retryAfterMs ?? null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function normalizeRetryDelay(value: number | null): number {
  if (value === null || !Number.isFinite(value)) {
    return 250;
  }
  return Math.max(50, Math.min(2_000, Math.trunc(value)));
}

function parseTextFrame(data: unknown): string {
  if (typeof data !== "string") {
    throw new GatewayProtocolError("Gateway sent a non-text WebSocket frame", {
      code: "NON_TEXT_FRAME",
    });
  }
  return data;
}

function parseGatewayError(error: unknown): GatewayProtocolError {
  if (!isRecord(error)) {
    return new GatewayProtocolError("Gateway request failed", { code: "GATEWAY_REQUEST_FAILED" });
  }
  const shape = error as GatewayResponseError;
  const code = typeof shape.code === "string" ? shape.code : "GATEWAY_REQUEST_FAILED";
  const message = typeof shape.message === "string" ? shape.message : "Gateway request failed";
  const retryable = shape.retryable === true;
  const retryAfterMs =
    typeof shape.retryAfterMs === "number" && Number.isFinite(shape.retryAfterMs)
      ? Math.max(0, Math.trunc(shape.retryAfterMs))
      : isRecord(shape.details) &&
          typeof shape.details.retryAfterMs === "number" &&
          Number.isFinite(shape.details.retryAfterMs)
        ? Math.max(0, Math.trunc(shape.details.retryAfterMs))
        : null;
  return new GatewayProtocolError(message, { code, retryable, retryAfterMs });
}

export function assertLoopbackGatewayUrl(rawUrl: string): URL {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new GatewayProtocolError("Gateway URL is invalid", { code: "INVALID_GATEWAY_URL" });
  }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") {
    throw new GatewayProtocolError("Gateway URL must use ws or wss", {
      code: "INVALID_GATEWAY_URL",
    });
  }
  const hostname = url.hostname.toLowerCase();
  if (hostname !== "127.0.0.1" && hostname !== "[::1]" && hostname !== "::1") {
    throw new GatewayProtocolError("Controller Gateway URL must be an IP loopback address", {
      code: "NON_LOOPBACK_GATEWAY_URL",
    });
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new GatewayProtocolError("Gateway URL contains forbidden components", {
      code: "INVALID_GATEWAY_URL",
    });
  }
  return url;
}

export type OpenClawGatewayClientOptions = {
  url: string;
  token: string;
  controllerVersion: string;
  socketFactory?: GatewaySocketFactory;
  connectBudgetMs?: number;
  requestTimeoutMs?: number;
  maximumPendingRequests?: number;
};

export class OpenClawGatewayClient {
  readonly #url: string;
  readonly #token: string;
  readonly #controllerVersion: string;
  readonly #socketFactory: GatewaySocketFactory;
  readonly #connectBudgetMs: number;
  readonly #requestTimeoutMs: number;
  readonly #maximumPendingRequests: number;

  #socket: GatewaySocket | null = null;
  #connectPromise: Promise<GatewayConnectionInfo> | null = null;
  #connectionInfo: GatewayConnectionInfo | null = null;
  #pending = new Map<string, PendingRequest>();
  #connectRequestId: string | null = null;
  #connectResolve: ((info: GatewayConnectionInfo) => void) | null = null;
  #connectReject: ((error: Error) => void) | null = null;
  #maximumFrameBytes = GATEWAY_PRECONNECT_MAX_BYTES;
  #lastSequence: number | null = null;
  #sequenceGapDetected = false;
  #challengeReceived = false;

  constructor(options: OpenClawGatewayClientOptions) {
    const url = assertLoopbackGatewayUrl(options.url);
    if (typeof options.token !== "string" || options.token.length < 16 || options.token.length > 4096) {
      throw new GatewayProtocolError("Gateway credential is missing or invalid", {
        code: "INVALID_GATEWAY_CREDENTIAL",
      });
    }
    if (
      typeof options.controllerVersion !== "string" ||
      options.controllerVersion.length === 0 ||
      options.controllerVersion.length > 128
    ) {
      throw new GatewayProtocolError("Controller version is invalid", {
        code: "INVALID_CONTROLLER_VERSION",
      });
    }

    this.#url = url.toString();
    this.#token = options.token;
    this.#controllerVersion = options.controllerVersion;
    this.#connectBudgetMs = options.connectBudgetMs ?? 10_000;
    this.#requestTimeoutMs = options.requestTimeoutMs ?? 5_000;
    this.#maximumPendingRequests = options.maximumPendingRequests ?? 32;
    this.#socketFactory =
      options.socketFactory ??
      ((socketUrl: string) => {
        if (typeof WebSocket !== "function") {
          throw new GatewayProtocolError("This Node.js runtime does not provide WebSocket", {
            code: "WEBSOCKET_UNAVAILABLE",
          });
        }
        return new WebSocket(socketUrl) as unknown as GatewaySocket;
      });
  }

  async connect(): Promise<GatewayConnectionInfo> {
    if (this.#connectionInfo !== null) {
      return this.getConnectionInfo();
    }
    if (this.#connectPromise !== null) {
      return this.#connectPromise;
    }

    this.#connectPromise = this.#connectWithinBudget();
    try {
      return await this.#connectPromise;
    } finally {
      this.#connectPromise = null;
    }
  }

  async #connectWithinBudget(): Promise<GatewayConnectionInfo> {
    const deadline = Date.now() + this.#connectBudgetMs;
    let lastError: Error | null = null;

    do {
      try {
        return await this.#connectOnce(Math.max(250, deadline - Date.now()));
      } catch (error) {
        lastError = error instanceof Error ? error : new Error("Gateway connection failed");
        this.#resetSocket();
        if (!(error instanceof GatewayProtocolError) || !error.retryable) {
          throw lastError;
        }
        const wait = normalizeRetryDelay(error.retryAfterMs);
        if (Date.now() + wait >= deadline) {
          break;
        }
        await delay(wait);
      }
    } while (Date.now() < deadline);

    throw lastError ?? new GatewayProtocolError("Gateway connection budget expired", {
      code: "CONNECT_TIMEOUT",
    });
  }

  #connectOnce(timeoutMs: number): Promise<GatewayConnectionInfo> {
    this.#resetProtocolState();
    const socket = this.#socketFactory(this.#url);
    this.#socket = socket;

    return new Promise<GatewayConnectionInfo>((resolve, reject) => {
      let settled = false;
      const finishResolve = (info: GatewayConnectionInfo): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        this.#connectResolve = null;
        this.#connectReject = null;
        resolve(info);
      };
      const finishReject = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        this.#connectResolve = null;
        this.#connectReject = null;
        reject(error);
      };

      this.#connectResolve = finishResolve;
      this.#connectReject = finishReject;

      const onMessage = (event: SocketEvent): void => {
        try {
          this.#handleMessage(event.data);
        } catch (error) {
          finishReject(error instanceof Error ? error : new Error("Gateway frame handling failed"));
          this.#resetSocket();
        }
      };
      const onError = (): void => {
        finishReject(
          new GatewayProtocolError("Gateway WebSocket reported an error", {
            code: "WEBSOCKET_ERROR",
            retryable: true,
          }),
        );
      };
      const onClose = (): void => {
        const error = new GatewayProtocolError("Gateway WebSocket closed", {
          code: "WEBSOCKET_CLOSED",
          retryable: true,
        });
        finishReject(error);
        this.#rejectPending(error);
        this.#connectionInfo = null;
      };

      socket.addEventListener("message", onMessage);
      socket.addEventListener("error", onError);
      socket.addEventListener("close", onClose);

      const timer = setTimeout(() => {
        finishReject(
          new GatewayProtocolError("Gateway handshake timed out", {
            code: "CONNECT_TIMEOUT",
            retryable: true,
          }),
        );
        this.#resetSocket();
      }, timeoutMs);
      timer.unref?.();
    });
  }

  #handleMessage(rawData: unknown): void {
    const text = parseTextFrame(rawData);
    if (Buffer.byteLength(text, "utf8") > this.#maximumFrameBytes) {
      throw new GatewayProtocolError("Gateway frame exceeds the negotiated size limit", {
        code: "FRAME_TOO_LARGE",
      });
    }

    let frame: unknown;
    try {
      frame = JSON.parse(text);
    } catch {
      throw new GatewayProtocolError("Gateway sent invalid JSON", { code: "INVALID_JSON" });
    }
    if (!isRecord(frame) || typeof frame.type !== "string") {
      throw new GatewayProtocolError("Gateway frame shape is invalid", {
        code: "INVALID_FRAME",
      });
    }

    if (frame.type === "event") {
      this.#handleEvent(frame);
      return;
    }
    if (frame.type === "res") {
      this.#handleResponse(frame);
      return;
    }
    throw new GatewayProtocolError("Gateway sent an unsupported frame type", {
      code: "INVALID_FRAME",
    });
  }

  #handleEvent(frame: Record<string, unknown>): void {
    if (frame.event === "connect.challenge" && this.#connectionInfo === null) {
      if (this.#challengeReceived) {
        throw new GatewayProtocolError("Gateway sent a duplicate connect challenge", {
          code: "DUPLICATE_CHALLENGE",
        });
      }
      if (!isRecord(frame.payload) || typeof frame.payload.nonce !== "string") {
        throw new GatewayProtocolError("Gateway connect challenge is invalid", {
          code: "INVALID_CHALLENGE",
        });
      }
      this.#challengeReceived = true;
      this.#sendConnectRequest();
      return;
    }

    if (typeof frame.seq === "number" && Number.isInteger(frame.seq) && frame.seq >= 0) {
      if (this.#lastSequence !== null && frame.seq !== this.#lastSequence + 1) {
        this.#sequenceGapDetected = true;
      }
      this.#lastSequence = frame.seq;
      if (this.#connectionInfo !== null && this.#sequenceGapDetected) {
        this.#connectionInfo = { ...this.#connectionInfo, sequenceGapDetected: true };
      }
    }
  }

  #sendConnectRequest(): void {
    if (this.#socket === null || this.#socket.readyState !== 1) {
      throw new GatewayProtocolError("Gateway socket is not open for handshake", {
        code: "SOCKET_NOT_OPEN",
        retryable: true,
      });
    }
    const id = randomUUID();
    this.#connectRequestId = id;
    const frame = {
      type: "req",
      id,
      method: "connect",
      params: {
        minProtocol: OPENCLAW_GATEWAY_PROTOCOL,
        maxProtocol: OPENCLAW_GATEWAY_PROTOCOL,
        client: {
          id: "gateway-client",
          displayName: "OpenClaw OS Controller",
          version: this.#controllerVersion,
          platform: process.platform,
          mode: "backend",
        },
        role: "operator",
        scopes: [...OPENCLAW_OPERATOR_SCOPES],
        caps: [],
        commands: [],
        permissions: {},
        auth: { token: this.#token },
        locale: "en-US",
        userAgent: `openclaw-os-controller/${this.#controllerVersion}`,
      },
    };
    const encoded = JSON.stringify(frame);
    if (Buffer.byteLength(encoded, "utf8") > GATEWAY_PRECONNECT_MAX_BYTES) {
      throw new GatewayProtocolError("Gateway connect frame is too large", {
        code: "FRAME_TOO_LARGE",
      });
    }
    this.#socket.send(encoded);
  }

  #handleResponse(frame: Record<string, unknown>): void {
    if (typeof frame.id !== "string" || typeof frame.ok !== "boolean") {
      throw new GatewayProtocolError("Gateway response frame is invalid", {
        code: "INVALID_RESPONSE",
      });
    }

    if (frame.id === this.#connectRequestId && this.#connectionInfo === null) {
      if (!frame.ok) {
        this.#connectReject?.(parseGatewayError(frame.error));
        return;
      }
      const info = this.#validateHello(frame.payload);
      this.#connectionInfo = info;
      this.#connectResolve?.(info);
      return;
    }

    const pending = this.#pending.get(frame.id);
    if (pending === undefined) {
      return;
    }
    this.#pending.delete(frame.id);
    clearTimeout(pending.timer);
    if (frame.ok) {
      pending.resolve(frame.payload);
    } else {
      pending.reject(parseGatewayError(frame.error));
    }
  }

  #validateHello(payload: unknown): GatewayConnectionInfo {
    if (!isRecord(payload) || payload.type !== "hello-ok") {
      throw new GatewayProtocolError("Gateway hello response is invalid", {
        code: "INVALID_HELLO",
      });
    }
    if (payload.protocol !== OPENCLAW_GATEWAY_PROTOCOL) {
      throw new GatewayProtocolError("Gateway negotiated an unsupported protocol", {
        code: "PROTOCOL_MISMATCH",
      });
    }
    if (!isRecord(payload.server) || typeof payload.server.version !== "string" || typeof payload.server.connId !== "string") {
      throw new GatewayProtocolError("Gateway server metadata is invalid", {
        code: "INVALID_HELLO",
      });
    }
    if (
      !isRecord(payload.features) ||
      !Array.isArray(payload.features.methods) ||
      !payload.features.methods.every((entry) => typeof entry === "string") ||
      !Array.isArray(payload.features.events) ||
      !payload.features.events.every((entry) => typeof entry === "string")
    ) {
      throw new GatewayProtocolError("Gateway feature metadata is invalid", {
        code: "INVALID_HELLO",
      });
    }
    if (!payload.features.methods.includes("health")) {
      throw new GatewayProtocolError("Gateway does not expose the required health method", {
        code: "INCOMPATIBLE_GATEWAY",
      });
    }
    if (
      !isRecord(payload.auth) ||
      payload.auth.role !== "operator" ||
      !Array.isArray(payload.auth.scopes) ||
      !payload.auth.scopes.every((entry) => typeof entry === "string")
    ) {
      throw new GatewayProtocolError("Gateway authorization metadata is invalid", {
        code: "INVALID_HELLO",
      });
    }
    const scopes = [...payload.auth.scopes].sort();
    if (scopes.length !== 1 || scopes[0] !== "operator.read") {
      throw new GatewayProtocolError("Gateway granted scopes outside the read-only policy", {
        code: "SCOPE_ESCALATION",
      });
    }
    if (
      !isRecord(payload.policy) ||
      typeof payload.policy.maxPayload !== "number" ||
      !Number.isInteger(payload.policy.maxPayload) ||
      payload.policy.maxPayload < 1
    ) {
      throw new GatewayProtocolError("Gateway payload policy is invalid", {
        code: "INVALID_HELLO",
      });
    }

    this.#maximumFrameBytes = Math.min(payload.policy.maxPayload, GATEWAY_HARD_MAX_BYTES);
    return {
      protocol: payload.protocol,
      serverVersion: payload.server.version,
      connectionId: payload.server.connId,
      methods: Object.freeze([...payload.features.methods]),
      events: Object.freeze([...payload.features.events]),
      scopes: Object.freeze(scopes),
      sequenceGapDetected: this.#sequenceGapDetected,
    };
  }

  async request(method: ReadOnlyGatewayMethod, params: unknown = {}): Promise<unknown> {
    if (!(READ_ONLY_GATEWAY_METHODS as readonly string[]).includes(method)) {
      throw new GatewayProtocolError("Gateway method is not in the read-only allowlist", {
        code: "METHOD_NOT_ALLOWED",
      });
    }
    await this.connect();
    if (this.#socket === null || this.#socket.readyState !== 1 || this.#connectionInfo === null) {
      throw new GatewayProtocolError("Gateway is not connected", {
        code: "NOT_CONNECTED",
        retryable: true,
      });
    }
    if (!this.#connectionInfo.methods.includes(method)) {
      throw new GatewayProtocolError("Gateway does not advertise the requested method", {
        code: "METHOD_UNAVAILABLE",
      });
    }
    if (this.#pending.size >= this.#maximumPendingRequests) {
      throw new GatewayProtocolError("Gateway request queue is full", {
        code: "REQUEST_LIMIT",
      });
    }

    const id = randomUUID();
    const frame = JSON.stringify({ type: "req", id, method, params });
    if (Buffer.byteLength(frame, "utf8") > this.#maximumFrameBytes) {
      throw new GatewayProtocolError("Gateway request exceeds the negotiated size limit", {
        code: "FRAME_TOO_LARGE",
      });
    }

    return await new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(
          new GatewayProtocolError("Gateway request timed out", {
            code: "REQUEST_TIMEOUT",
            retryable: true,
          }),
        );
      }, this.#requestTimeoutMs);
      timer.unref?.();
      this.#pending.set(id, { resolve, reject, timer });
      try {
        this.#socket?.send(frame);
      } catch (error) {
        this.#pending.delete(id);
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error("Gateway request send failed"));
      }
    });
  }

  getConnectionInfo(): GatewayConnectionInfo {
    if (this.#connectionInfo === null) {
      throw new GatewayProtocolError("Gateway is not connected", { code: "NOT_CONNECTED" });
    }
    return {
      ...this.#connectionInfo,
      methods: [...this.#connectionInfo.methods],
      events: [...this.#connectionInfo.events],
      scopes: [...this.#connectionInfo.scopes],
    };
  }

  close(): void {
    this.#resetSocket();
  }

  #rejectPending(error: Error): void {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  #resetProtocolState(): void {
    this.#connectionInfo = null;
    this.#connectRequestId = null;
    this.#maximumFrameBytes = GATEWAY_PRECONNECT_MAX_BYTES;
    this.#lastSequence = null;
    this.#sequenceGapDetected = false;
    this.#challengeReceived = false;
  }

  #resetSocket(): void {
    const socket = this.#socket;
    this.#socket = null;
    this.#connectRequestId = null;
    this.#connectResolve = null;
    this.#connectReject = null;
    this.#connectionInfo = null;
    this.#rejectPending(
      new GatewayProtocolError("Gateway connection was reset", {
        code: "CONNECTION_RESET",
        retryable: true,
      }),
    );
    if (socket !== null) {
      try {
        socket.close(1000, "controller reset");
      } catch {
        // Best-effort socket cleanup only.
      }
    }
  }
}
