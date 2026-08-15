export const APPLIANCE_API_VERSION = "v1" as const;
export const HOSTD_MAX_FRAME_BYTES = 16 * 1024;
export const HOSTD_REQUEST_ID_PATTERN = /^[A-Za-z0-9._:-]{1,64}$/;

export const ALLOWED_SERVICE_UNITS = [
  "openclaw.service",
  "openclaw-podman.service",
  "openclaw-controller.service",
  "openclaw-hostd.service",
] as const;

export type AllowedServiceUnit = (typeof ALLOWED_SERVICE_UNITS)[number];

export type SystemStatus = {
  hostname: string;
  architecture: string;
  kernelRelease: string;
  uptimeSeconds: number;
};

export type StorageStatus = {
  path: string;
  blockSizeBytes: string;
  totalBytes: string;
  availableBytes: string;
};

export type ServiceStatus = {
  unit: AllowedServiceUnit;
  loadState: string;
  activeState: string;
  subState: string;
  unitFileState: string;
  mainPid: number | null;
  execMainStatus: number | null;
};

export type HostdRequest =
  | {
      version: typeof APPLIANCE_API_VERSION;
      id: string;
      operation: "system.status";
      params: Record<string, never>;
    }
  | {
      version: typeof APPLIANCE_API_VERSION;
      id: string;
      operation: "storage.status";
      params: Record<string, never>;
    }
  | {
      version: typeof APPLIANCE_API_VERSION;
      id: string;
      operation: "service.status";
      params: { unit: AllowedServiceUnit };
    };

export type HostdResult = SystemStatus | StorageStatus | ServiceStatus;

export const HOSTD_ERROR_CODES = [
  "INVALID_REQUEST",
  "UNSUPPORTED_OPERATION",
  "OPERATION_FAILED",
  "FRAME_TOO_LARGE",
  "TIMEOUT",
] as const;

export type HostdErrorCode = (typeof HOSTD_ERROR_CODES)[number];

export type HostdResponse =
  | {
      version: typeof APPLIANCE_API_VERSION;
      id: string;
      ok: true;
      result: HostdResult;
    }
  | {
      version: typeof APPLIANCE_API_VERSION;
      id: string;
      ok: false;
      error: {
        code: HostdErrorCode;
        message: string;
      };
    };

export class ContractValidationError extends Error {
  readonly code: HostdErrorCode;

  constructor(message: string, code: HostdErrorCode = "INVALID_REQUEST") {
    super(message);
    this.name = "ContractValidationError";
    this.code = code;
  }
}

export function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function requireExactKeys(
  value: Record<string, unknown>,
  expected: readonly string[],
  context: string,
): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new ContractValidationError(`${context} contains unexpected or missing fields`);
  }
}

function requireRequestId(value: unknown): string {
  if (typeof value !== "string" || !HOSTD_REQUEST_ID_PATTERN.test(value)) {
    throw new ContractValidationError("request id is invalid");
  }
  return value;
}

function requireBoundedString(value: unknown, context: string, maximumLength: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new ContractValidationError(`${context} is invalid`);
  }
  return value;
}

function requireNonNegativeInteger(value: unknown, context: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new ContractValidationError(`${context} is invalid`);
  }
  return value;
}

function requireNullableInteger(value: unknown, context: string): number | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new ContractValidationError(`${context} is invalid`);
  }
  return value;
}

function requireDecimalString(value: unknown, context: string): string {
  if (typeof value !== "string" || !/^[0-9]{1,32}$/.test(value)) {
    throw new ContractValidationError(`${context} is invalid`);
  }
  return value;
}

function requireEmptyParams(value: unknown): Record<string, never> {
  if (!isPlainRecord(value) || Object.keys(value).length !== 0) {
    throw new ContractValidationError("operation params must be an empty object");
  }
  return value as Record<string, never>;
}

function requireAllowedUnit(value: unknown): AllowedServiceUnit {
  if (
    typeof value !== "string" ||
    !(ALLOWED_SERVICE_UNITS as readonly string[]).includes(value)
  ) {
    throw new ContractValidationError("service unit is not allowlisted");
  }
  return value as AllowedServiceUnit;
}

function parseSystemStatus(value: unknown): SystemStatus {
  if (!isPlainRecord(value)) {
    throw new ContractValidationError("system status must be an object");
  }
  requireExactKeys(
    value,
    ["hostname", "architecture", "kernelRelease", "uptimeSeconds"],
    "system status",
  );
  return {
    hostname: requireBoundedString(value.hostname, "hostname", 255),
    architecture: requireBoundedString(value.architecture, "architecture", 64),
    kernelRelease: requireBoundedString(value.kernelRelease, "kernel release", 256),
    uptimeSeconds: requireNonNegativeInteger(value.uptimeSeconds, "uptime"),
  };
}

function parseStorageStatus(value: unknown): StorageStatus {
  if (!isPlainRecord(value)) {
    throw new ContractValidationError("storage status must be an object");
  }
  requireExactKeys(
    value,
    ["path", "blockSizeBytes", "totalBytes", "availableBytes"],
    "storage status",
  );
  if (value.path !== "/var/lib/openclaw") {
    throw new ContractValidationError("storage status path is invalid");
  }
  return {
    path: value.path,
    blockSizeBytes: requireDecimalString(value.blockSizeBytes, "storage block size"),
    totalBytes: requireDecimalString(value.totalBytes, "storage total bytes"),
    availableBytes: requireDecimalString(value.availableBytes, "storage available bytes"),
  };
}

function parseServiceStatus(value: unknown, expectedUnit: AllowedServiceUnit): ServiceStatus {
  if (!isPlainRecord(value)) {
    throw new ContractValidationError("service status must be an object");
  }
  requireExactKeys(
    value,
    [
      "unit",
      "loadState",
      "activeState",
      "subState",
      "unitFileState",
      "mainPid",
      "execMainStatus",
    ],
    "service status",
  );
  if (value.unit !== expectedUnit) {
    throw new ContractValidationError("service status unit does not match the request");
  }
  return {
    unit: expectedUnit,
    loadState: requireBoundedString(value.loadState, "service load state", 64),
    activeState: requireBoundedString(value.activeState, "service active state", 64),
    subState: requireBoundedString(value.subState, "service sub-state", 64),
    unitFileState: requireBoundedString(value.unitFileState, "service unit-file state", 64),
    mainPid: requireNullableInteger(value.mainPid, "service main PID"),
    execMainStatus: requireNullableInteger(value.execMainStatus, "service exit status"),
  };
}

function parseHostdResult(value: unknown, request: HostdRequest): HostdResult {
  switch (request.operation) {
    case "system.status":
      return parseSystemStatus(value);
    case "storage.status":
      return parseStorageStatus(value);
    case "service.status":
      return parseServiceStatus(value, request.params.unit);
  }
}

export function parseHostdRequest(value: unknown): HostdRequest {
  if (!isPlainRecord(value)) {
    throw new ContractValidationError("request must be a JSON object");
  }
  requireExactKeys(value, ["version", "id", "operation", "params"], "request");

  if (value.version !== APPLIANCE_API_VERSION) {
    throw new ContractValidationError("unsupported appliance API version");
  }
  const id = requireRequestId(value.id);
  if (typeof value.operation !== "string") {
    throw new ContractValidationError("operation must be a string");
  }

  switch (value.operation) {
    case "system.status":
      return {
        version: APPLIANCE_API_VERSION,
        id,
        operation: value.operation,
        params: requireEmptyParams(value.params),
      };
    case "storage.status":
      return {
        version: APPLIANCE_API_VERSION,
        id,
        operation: value.operation,
        params: requireEmptyParams(value.params),
      };
    case "service.status": {
      if (!isPlainRecord(value.params)) {
        throw new ContractValidationError("service.status params must be an object");
      }
      requireExactKeys(value.params, ["unit"], "service.status params");
      return {
        version: APPLIANCE_API_VERSION,
        id,
        operation: value.operation,
        params: { unit: requireAllowedUnit(value.params.unit) },
      };
    }
    default:
      throw new ContractValidationError("operation is not supported", "UNSUPPORTED_OPERATION");
  }
}

export function parseHostdResponse(value: unknown, request: HostdRequest): HostdResponse {
  if (!isPlainRecord(value)) {
    throw new ContractValidationError("response must be a JSON object");
  }
  if (value.version !== APPLIANCE_API_VERSION || value.id !== request.id) {
    throw new ContractValidationError("response correlation failed");
  }
  if (value.ok === true) {
    requireExactKeys(value, ["version", "id", "ok", "result"], "response");
    return {
      version: APPLIANCE_API_VERSION,
      id: request.id,
      ok: true,
      result: parseHostdResult(value.result, request),
    };
  }
  if (value.ok === false) {
    requireExactKeys(value, ["version", "id", "ok", "error"], "response");
    if (!isPlainRecord(value.error)) {
      throw new ContractValidationError("response error must be an object");
    }
    requireExactKeys(value.error, ["code", "message"], "response error");
    if (
      typeof value.error.code !== "string" ||
      !(HOSTD_ERROR_CODES as readonly string[]).includes(value.error.code)
    ) {
      throw new ContractValidationError("response error code is invalid");
    }
    return {
      version: APPLIANCE_API_VERSION,
      id: request.id,
      ok: false,
      error: {
        code: value.error.code as HostdErrorCode,
        message: requireBoundedString(value.error.message, "response error message", 256),
      },
    };
  }
  throw new ContractValidationError("response ok field is invalid");
}

export function createHostdRequest(
  id: string,
  operation: "system.status" | "storage.status",
): HostdRequest;
export function createHostdRequest(
  id: string,
  operation: "service.status",
  params: { unit: AllowedServiceUnit },
): HostdRequest;
export function createHostdRequest(
  id: string,
  operation: HostdRequest["operation"],
  params: { unit: AllowedServiceUnit } | Record<string, never> = {},
): HostdRequest {
  return parseHostdRequest({
    version: APPLIANCE_API_VERSION,
    id,
    operation,
    params,
  });
}

export function encodeJsonLine(value: unknown, maximumBytes = HOSTD_MAX_FRAME_BYTES): string {
  const encoded = `${JSON.stringify(value)}\n`;
  if (Buffer.byteLength(encoded, "utf8") > maximumBytes) {
    throw new ContractValidationError("encoded frame exceeds maximum size", "FRAME_TOO_LARGE");
  }
  return encoded;
}
