import { promises as fs } from "node:fs";
import { fileURLToPath } from "node:url";
import { OpenClawGatewayClient } from "../../../packages/gateway-client/src/index.ts";
import { readCompatibilityManifest } from "./compatibility.ts";
import { readGatewayCredential } from "./credentials.ts";
import { OpenClawGatewayStatusProvider } from "./gateway-status.ts";
import { HostdClient } from "./hostd-client.ts";
import { createControllerServer } from "./server.ts";

const CONTROLLER_HOST = "127.0.0.1";
const CONTROLLER_PORT = 9080;
const DEFAULT_GATEWAY_URL = "ws://127.0.0.1:18789";
const HOSTD_SOCKET = "/run/openclaw-os/hostd.sock";

async function readControllerVersion(): Promise<string> {
  const packagePath = fileURLToPath(new URL("../../../package.json", import.meta.url));
  const parsed: unknown = JSON.parse(await fs.readFile(packagePath, "utf8"));
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    !("version" in parsed) ||
    typeof parsed.version !== "string" ||
    parsed.version.length === 0
  ) {
    throw new Error("controller package version is invalid");
  }
  return parsed.version;
}

function resolveGatewayUrl(): string {
  const configured = process.env.OPENCLAW_CONTROLLER_GATEWAY_URL ?? DEFAULT_GATEWAY_URL;
  if (configured.length > 256 || configured.includes("\0")) {
    throw new Error("controller Gateway URL is invalid");
  }
  return configured;
}

function resolveCredentialPath(): string {
  const credentialDirectory = process.env.CREDENTIALS_DIRECTORY;
  if (
    typeof credentialDirectory !== "string" ||
    !credentialDirectory.startsWith("/") ||
    credentialDirectory.includes("\0")
  ) {
    throw new Error("systemd credential directory is unavailable");
  }
  return `${credentialDirectory}/gateway-token`;
}

async function main(): Promise<void> {
  const controllerVersion = await readControllerVersion();
  const compatibilityPath = fileURLToPath(
    new URL("../../../config/openclaw-compatibility.json", import.meta.url),
  );
  const compatibility = await readCompatibilityManifest(compatibilityPath);
  const token = await readGatewayCredential(resolveCredentialPath());

  const gatewayClient = new OpenClawGatewayClient({
    url: resolveGatewayUrl(),
    token,
    controllerVersion,
  });
  const gateway = new OpenClawGatewayStatusProvider(gatewayClient);
  const hostd = new HostdClient({ socketPath: HOSTD_SOCKET });
  const server = createControllerServer({
    controllerVersion,
    compatibility,
    gateway,
    hostd,
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(CONTROLLER_PORT, CONTROLLER_HOST, () => resolve());
  });

  const shutdown = (): void => {
    gateway.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5_000).unref();
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
}

main().catch(() => {
  process.exitCode = 1;
});
