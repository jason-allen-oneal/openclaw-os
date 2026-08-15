import { promises as fs } from "node:fs";

export type CompatibilityManifest = {
  schemaVersion: 1;
  openclawOsVersion: string;
  controlPlanePhase: number;
  gatewayProtocol: {
    minimum: number;
    maximum: number;
    requiredMethods: string[];
    operatorScopes: string[];
  };
  testedOpenclawVersions: string[];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.length > 0 && value.every((entry) => typeof entry === "string");
}

export async function readCompatibilityManifest(filePath: string): Promise<CompatibilityManifest> {
  const status = await fs.lstat(filePath);
  if (!status.isFile() || status.isSymbolicLink() || status.size > 64 * 1024) {
    throw new Error("compatibility manifest file is invalid");
  }
  const parsed: unknown = JSON.parse(await fs.readFile(filePath, "utf8"));
  if (
    !isRecord(parsed) ||
    parsed.schemaVersion !== 1 ||
    typeof parsed.openclawOsVersion !== "string" ||
    parsed.openclawOsVersion.length === 0 ||
    typeof parsed.controlPlanePhase !== "number" ||
    !Number.isInteger(parsed.controlPlanePhase) ||
    parsed.controlPlanePhase < 1 ||
    !isRecord(parsed.gatewayProtocol) ||
    typeof parsed.gatewayProtocol.minimum !== "number" ||
    typeof parsed.gatewayProtocol.maximum !== "number" ||
    !Number.isInteger(parsed.gatewayProtocol.minimum) ||
    !Number.isInteger(parsed.gatewayProtocol.maximum) ||
    parsed.gatewayProtocol.minimum > parsed.gatewayProtocol.maximum ||
    !isStringArray(parsed.gatewayProtocol.requiredMethods) ||
    !isStringArray(parsed.gatewayProtocol.operatorScopes) ||
    !isStringArray(parsed.testedOpenclawVersions)
  ) {
    throw new Error("compatibility manifest schema is invalid");
  }
  return parsed as CompatibilityManifest;
}
