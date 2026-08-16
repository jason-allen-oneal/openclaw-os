import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import {
  HOSTD_MAX_FRAME_BYTES,
  createHostdRequest,
  encodeJsonLine,
  parseHostdResponse,
  type AllowedServiceUnit,
  type HostdResponse,
  type ServiceStatus,
  type StorageStatus,
  type SystemStatus,
} from "../../../packages/appliance-contracts/src/index.ts";

export class HostdClientError extends Error {
  readonly code: string;

  constructor(message: string, code = "HOSTD_UNAVAILABLE") {
    super(message);
    this.name = "HostdClientError";
    this.code = code;
  }
}

export type HostdClientOptions = {
  socketPath: string;
  timeoutMs?: number;
};

export class HostdClient {
  readonly #socketPath: string;
  readonly #timeoutMs: number;

  constructor(options: HostdClientOptions) {
    if (!options.socketPath.startsWith("/") || options.socketPath.includes("\0")) {
      throw new HostdClientError("hostd socket path must be absolute", "INVALID_SOCKET_PATH");
    }
    this.#socketPath = options.socketPath;
    this.#timeoutMs = options.timeoutMs ?? 2_500;
  }

  async systemStatus(): Promise<SystemStatus> {
    const response = await this.#request(createHostdRequest(randomUUID(), "system.status"));
    return response as SystemStatus;
  }

  async storageStatus(): Promise<StorageStatus> {
    const response = await this.#request(createHostdRequest(randomUUID(), "storage.status"));
    return response as StorageStatus;
  }

  async serviceStatus(unit: AllowedServiceUnit): Promise<ServiceStatus> {
    const response = await this.#request(
      createHostdRequest(randomUUID(), "service.status", { unit }),
    );
    return response as ServiceStatus;
  }

  #request(request: ReturnType<typeof createHostdRequest>): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const socket = createConnection(this.#socketPath);
      let buffered = "";
      let bytesReceived = 0;
      let settled = false;

      const finish = (callback: () => void): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        callback();
      };

      const timer = setTimeout(() => {
        finish(() => reject(new HostdClientError("hostd request timed out", "TIMEOUT")));
      }, this.#timeoutMs);
      timer.unref?.();

      socket.once("connect", () => {
        try {
          socket.write(encodeJsonLine(request));
        } catch {
          finish(() => reject(new HostdClientError("hostd request encoding failed")));
        }
      });
      socket.on("data", (chunk: Buffer) => {
        if (settled) {
          return;
        }
        bytesReceived += chunk.length;
        if (bytesReceived > HOSTD_MAX_FRAME_BYTES) {
          finish(() => reject(new HostdClientError("hostd response is too large", "FRAME_TOO_LARGE")));
          return;
        }
        buffered += chunk.toString("utf8");
        const newline = buffered.indexOf("\n");
        if (newline === -1) {
          return;
        }
        const line = buffered.slice(0, newline);
        const trailing = buffered.slice(newline + 1);
        if (trailing.trim().length !== 0 || line.trim().length === 0) {
          finish(() => reject(new HostdClientError("hostd response framing is invalid")));
          return;
        }
        try {
          const parsed = parseHostdResponse(JSON.parse(line), request) as HostdResponse;
          if (!parsed.ok) {
            finish(() => reject(new HostdClientError("hostd rejected the request", parsed.error.code)));
            return;
          }
          finish(() => resolve(parsed.result));
        } catch {
          finish(() => reject(new HostdClientError("hostd response failed validation")));
        }
      });
      socket.once("error", () => {
        finish(() => reject(new HostdClientError("hostd is unavailable")));
      });
      socket.once("end", () => {
        if (!settled) {
          finish(() => reject(new HostdClientError("hostd closed without a response")));
        }
      });
    });
  }
}
