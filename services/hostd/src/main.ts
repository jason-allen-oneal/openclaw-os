import { createHostdServer } from "./server.ts";

const SOCKET_PATH = "/run/openclaw-os/hostd.sock";

async function main(): Promise<void> {
  const configuredPath = process.env.OPENCLAW_HOSTD_SOCKET ?? SOCKET_PATH;
  if (configuredPath !== SOCKET_PATH) {
    throw new Error("hostd socket override is not permitted in the appliance service");
  }

  const server = await createHostdServer({ socketPath: configuredPath });
  const shutdown = (): void => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5_000).unref();
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
}

main().catch(() => {
  process.exitCode = 1;
});
