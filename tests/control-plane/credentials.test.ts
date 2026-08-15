import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  CredentialError,
  readGatewayCredential,
} from "../../services/controller/src/credentials.ts";

test("controller accepts only a private regular credential file", async () => {
  const directory = await fs.mkdtemp(join(tmpdir(), "openclaw-credential-test-"));
  const credentialPath = join(directory, "gateway-token");
  const token = "d".repeat(64);
  await fs.writeFile(credentialPath, `${token}\n`, { mode: 0o600 });
  assert.equal(await readGatewayCredential(credentialPath), token);

  await fs.chmod(credentialPath, 0o644);
  await assert.rejects(
    readGatewayCredential(credentialPath),
    (error: unknown) => error instanceof CredentialError,
  );

  const linkPath = join(directory, "gateway-token-link");
  await fs.symlink(credentialPath, linkPath);
  await assert.rejects(readGatewayCredential(linkPath));
  await fs.rm(directory, { recursive: true, force: true });
});
