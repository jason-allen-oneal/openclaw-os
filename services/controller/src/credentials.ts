import { promises as fs } from "node:fs";

const MAX_CREDENTIAL_BYTES = 4 * 1024;

export class CredentialError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CredentialError";
  }
}

export async function readGatewayCredential(filePath: string): Promise<string> {
  if (!filePath.startsWith("/") || filePath.includes("\0")) {
    throw new CredentialError("credential path must be absolute");
  }
  const status = await fs.lstat(filePath);
  if (!status.isFile() || status.isSymbolicLink()) {
    throw new CredentialError("credential path is not a regular file");
  }
  if ((status.mode & 0o077) !== 0) {
    throw new CredentialError("credential file permissions are too broad");
  }
  if (status.size < 16 || status.size > MAX_CREDENTIAL_BYTES) {
    throw new CredentialError("credential file size is invalid");
  }

  const raw = await fs.readFile(filePath, "utf8");
  const token = raw.endsWith("\n") ? raw.slice(0, -1).replace(/\r$/, "") : raw;
  if (
    token.length < 16 ||
    token.length > MAX_CREDENTIAL_BYTES ||
    !/^[!-~]+$/.test(token)
  ) {
    throw new CredentialError("credential content is invalid");
  }
  return token;
}
