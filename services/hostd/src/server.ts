import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import { createServer, createConnection, type Server, type Socket } from "node:net";
import os from "node:os";
import { dirname } from "node:path";
import {
  ALLOWED_SERVICE_UNITS,
  APPLIANCE_API_VERSION,
  ContractValidationError,
  HOSTD_MAX_FRAME_BYTES,
  HOSTD_REQUEST_ID_PATTERN,
  encodeJsonLine,
  isPlainRecord,
  parseHostdRequest,
  type AllowedServiceUnit,
  type HostdErrorCode,
  type HostdRequest,
  type HostdResult,
  type ServiceStatus,
  type StorageStatus,
  type SystemStatus,
} from "../../../packages/appliance-contracts/src/index.ts";

const REQUEST_TIMEOUT_MS = 2_000;
const SYSTEMCTL_TIMEOUT_MS = 2_000;
const MAX_SYSTEMCTL_OUTPUT_BYTES = 32 * 1024;

export type HostdOperationHandlers = {
  systemStatus(): Promise<SystemStatus>;
  storageStatus(): Promise<StorageStatus>;
  serviceStatus(unit: AllowedServiceUnit): Promise<ServiceStatus>;
};

export type HostdServerOptions = {
  socketPath: string;
  handlers?: HostdOperationHandlers;
  requestTimeoutMs?: number;
  socketMode?: number;
};

export class HostdServerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "HostdServerError";
  }
}

function parseIntegerOrNull(value: string | undefined): number | null {
  if (value === undefined || !/^-?[0-9]+$/.test(value)) {
    return null;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function runSystemctlShow(unit: AllowedServiceUnit): Promise<ServiceStatus> {
  if (!(ALLOWED_SERVICE_UNITS as readonly string[]).includes(unit)) {
    return Promise.reject(new HostdServerError("service unit is not allowlisted"));
  }

  return new Promise((resolve, reject) => {
    execFile(
      "/usr/bin/systemctl",
      [
        "show",
        "--no-pager",
        "--property=LoadState,ActiveState,SubState,UnitFileState,MainPID,ExecMainStatus",
        unit,
      ],
      {
        encoding: "utf8",
        timeout: SYSTEMCTL_TIMEOUT_MS,
        maxBuffer: MAX_SYSTEMCTL_OUTPUT_BYTES,
        env: {
          PATH: "/usr/sbin:/usr/bin:/sbin:/bin",
          LANG: "C.UTF-8",
        },
      },
      (error, stdout) => {
        if (error !== null) {
          reject(new HostdServerError("systemd status query failed"));
          return;
        }
        const fields = new Map<string, string>();
        for (const line of stdout.split("\n")) {
          const separator = line.indexOf("=");
          if (separator <= 0) {
            continue;
          }
          fields.set(line.slice(0, separator), line.slice(separator + 1));
        }
        resolve({
          unit,
          loadState: fields.get("LoadState") ?? "unknown",
          activeState: fields.get("ActiveState") ?? "unknown",
          subState: fields.get("SubState") ?? "unknown",
          unitFileState: fields.get("UnitFileState") ?? "unknown",
          mainPid: parseIntegerOrNull(fields.get("MainPID")),
          execMainStatus: parseIntegerOrNull(fields.get("ExecMainStatus")),
        });
      },
    );
  });
}

export const defaultHostdHandlers: HostdOperationHandlers = {
  async systemStatus(): Promise<SystemStatus> {
    return {
      hostname: os.hostname(),
      architecture: process.arch,
      kernelRelease: os.release(),
      uptimeSeconds: Math.max(0, Math.trunc(os.uptime())),
    };
  },

  async storageStatus(): Promise<StorageStatus> {
    const path = "/var/lib/openclaw";
    const status = await fs.statfs(path, { bigint: true });
    const blockSize = status.bsize;
    return {
      path,
      blockSizeBytes: blockSize.toString(10),
      totalBytes: (blockSize * status.blocks).toString(10),
      availableBytes: (blockSize * status.bavail).toString(10),
    };
  },

  async serviceStatus(unit: AllowedServiceUnit): Promise<ServiceStatus> {
    return await runSystemctlShow(unit);
  },
};

function safeRequestId(value: unknown): string {
  if (isPlainRecord(value) && typeof value.id === "string" && HOSTD_REQUEST_ID_PATTERN.test(value.id)) {
    return value.id;
  }
  return "invalid";
}

function writeError(
  socket: Socket,
  id: string,
  code: HostdErrorCode,
  message: string,
): void {
  if (socket.destroyed) {
    return;
  }
  try {
    socket.end(
      encodeJsonLine({
        version: APPLIANCE_API_VERSION,
        id,
        ok: false,
        error: { code, message },
      }),
    );
  } catch {
    socket.destroy();
  }
}

async function executeRequest(
  request: HostdRequest,
  handlers: HostdOperationHandlers,
): Promise<HostdResult> {
  switch (request.operation) {
    case "system.status":
      return await handlers.systemStatus();
    case "storage.status":
      return await handlers.storageStatus();
    case "service.status":
      return await handlers.serviceStatus(request.params.unit);
  }
}

function handleConnection(
  socket: Socket,
  handlers: HostdOperationHandlers,
  requestTimeoutMs: number,
): void {
  let bytesReceived = 0;
  let buffered = "";
  let completed = false;

  const timer = setTimeout(() => {
    if (!completed) {
      completed = true;
      writeError(socket, "invalid", "TIMEOUT", "request timed out");
    }
  }, requestTimeoutMs);
  timer.unref?.();

  const finish = (): void => {
    clearTimeout(timer);
  };

  socket.setNoDelay(true);
  socket.on("error", finish);
  socket.on("close", finish);

  socket.on("data", (chunk: Buffer) => {
    if (completed) {
      return;
    }
    bytesReceived += chunk.length;
    if (bytesReceived > HOSTD_MAX_FRAME_BYTES) {
      completed = true;
      writeError(socket, "invalid", "FRAME_TOO_LARGE", "request frame is too large");
      return;
    }

    buffered += chunk.toString("utf8");
    const newline = buffered.indexOf("\n");
    if (newline === -1) {
      return;
    }
    completed = true;
    clearTimeout(timer);

    const line = buffered.slice(0, newline);
    const trailing = buffered.slice(newline + 1);
    if (trailing.trim().length !== 0 || line.trim().length === 0) {
      writeError(socket, "invalid", "INVALID_REQUEST", "exactly one JSON request is required");
      return;
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(line);
    } catch {
      writeError(socket, "invalid", "INVALID_REQUEST", "request is not valid JSON");
      return;
    }

    let request: HostdRequest;
    try {
      request = parseHostdRequest(decoded);
    } catch (error) {
      const code = error instanceof ContractValidationError ? error.code : "INVALID_REQUEST";
      writeError(socket, safeRequestId(decoded), code, "request failed validation");
      return;
    }

    void executeRequest(request, handlers)
      .then((result) => {
        if (!socket.destroyed) {
          socket.end(
            encodeJsonLine({
              version: APPLIANCE_API_VERSION,
              id: request.id,
              ok: true,
              result,
            }),
          );
        }
      })
      .catch(() => {
        writeError(socket, request.id, "OPERATION_FAILED", "host operation failed");
      });
  });
}

type ExistingSocketState = "active" | "stale" | "uncertain";

function probeExistingSocket(socketPath: string): Promise<ExistingSocketState> {
  return new Promise((resolve) => {
    const socket = createConnection(socketPath);
    let settled = false;
    const finish = (state: ExistingSocketState): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(state);
    };
    const timer = setTimeout(() => finish("uncertain"), 250);
    timer.unref?.();
    socket.once("connect", () => finish("active"));
    socket.once("error", (error: NodeJS.ErrnoException) => {
      finish(error.code === "ECONNREFUSED" || error.code === "ENOENT" ? "stale" : "uncertain");
    });
  });
}

function hasErrorCode(error: unknown, code: string): boolean {
  return (
    error !== null &&
    typeof error === "object" &&
    "code" in error &&
    (error as { code?: unknown }).code === code
  );
}

async function prepareSocketPath(socketPath: string): Promise<void> {
  let status;
  try {
    status = await fs.lstat(socketPath);
  } catch (error) {
    if (hasErrorCode(error, "ENOENT")) {
      return;
    }
    throw error;
  }

  if (status.isSymbolicLink() || !status.isSocket()) {
    throw new HostdServerError("refusing to replace a non-socket hostd path");
  }
  const existingState = await probeExistingSocket(socketPath);
  if (existingState === "active") {
    throw new HostdServerError("hostd socket is already active");
  }
  if (existingState !== "stale") {
    throw new HostdServerError("hostd socket state could not be verified safely");
  }
  await fs.unlink(socketPath);
}

export async function createHostdServer(options: HostdServerOptions): Promise<Server> {
  if (!options.socketPath.startsWith("/") || options.socketPath.includes("\0")) {
    throw new HostdServerError("hostd socket path must be absolute");
  }
  const handlers = options.handlers ?? defaultHostdHandlers;
  const requestTimeoutMs = options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
  const socketMode = options.socketMode ?? 0o660;

  await fs.mkdir(dirname(options.socketPath), {
    recursive: true,
    mode: 0o750,
  });
  await prepareSocketPath(options.socketPath);

  const server = createServer((socket) => handleConnection(socket, handlers, requestTimeoutMs));

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = (): void => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(options.socketPath);
  });
  await fs.chmod(options.socketPath, socketMode);
  return server;
}
