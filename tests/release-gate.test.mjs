import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  validateEvidence,
  validatePolicy
} from "../scripts/release-gate.mjs";

const policy = JSON.parse(
  readFileSync(
    new URL("../config/release-promotion-policy.json", import.meta.url),
    "utf8"
  )
);
const now = new Date("2026-08-16T12:00:00Z");

function alphaEvidence() {
  return {
    schemaVersion: 1,
    channel: "alpha",
    sourceCommit: "a".repeat(40),
    generatedAt: "2026-08-16T11:45:00Z",
    artifact: {
      name: "openclaw-os-0.1.0-alpha.1-amd64.iso",
      digestAlgorithm: "sha256",
      testedDigest: "b".repeat(64),
      promotedDigest: "b".repeat(64),
      sourceCommit: "a".repeat(40),
      builtAt: "2026-08-15T11:45:00Z",
      actionsArtifact: {
        id: 1,
        name: "openclaw-os-amd64",
        expired: false,
        sizeInBytes: 1024,
        archiveDigest: "sha256:" + "d".repeat(64),
        workflowRunHeadSha: "a".repeat(40)
      }
    },
    checks: {
      validate: {
        status: "success",
        headSha: "a".repeat(40),
        runUrl: "https://github.com/example/openclaw-os/actions/runs/1"
      },
      "build-amd64": {
        status: "success",
        headSha: "a".repeat(40),
        runUrl: "https://github.com/example/openclaw-os/actions/runs/2"
      }
    },
    evidence: [
      "artifact-manifest",
      "checksums",
      "sbom",
      "uefi-live-boot",
      "clean-install",
      "update-code-rollback",
      "known-limitations"
    ].map((name) => ({
      name,
      url: "https://github.com/example/openclaw-os/actions/runs/2#" + name,
      sha256: "c".repeat(64)
    })),
    issues: [
      ...[12, 13].map((number) => ({
        number,
        state: "closed",
        url: `https://github.com/example/openclaw-os/issues/${number}`
      })),
      ...[6, 7, 8, 9, 10, 11, 14].map((number) => ({
        number,
        state: "open",
        url: `https://github.com/example/openclaw-os/issues/${number}`
      }))
    ],
    approvals: [
      {
        role: "release-owner",
        login: "maintainer",
        approvedAt: "2026-08-16T11:30:00Z",
        method: "protected-environment",
        runUrl: "https://github.com/example/openclaw-os/actions/runs/3"
      }
    ],
    waivers: [],
    releaseNotes: {
      knownLimitations: ["alpha"],
      testedHardware: ["QEMU"],
      supportedUpgradePaths: ["fresh install"],
      checksums: "SHA256SUMS",
      sbom: "SPDX 2.3",
      signingIdentities: ["development identity"],
      rollbackProcedure: "docs/UPDATES.md"
    }
  };
}

test("policy is valid", () => {
  assert.equal(validatePolicy(policy), policy);
});

test("valid alpha evidence passes", () => {
  assert.equal(validateEvidence(policy, alphaEvidence(), now), true);
});

test("an allowed blocker may already be closed", () => {
  const evidence = alphaEvidence();
  evidence.issues.find((issue) => issue.number === 14).state = "closed";
  assert.equal(validateEvidence(policy, evidence, now), true);
});

test("digest mismatch fails", () => {
  const evidence = alphaEvidence();
  evidence.artifact.promotedDigest = "c".repeat(64);
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /digest differs/
  );
});

test("missing check fails", () => {
  const evidence = alphaEvidence();
  evidence.checks.validate.status = "failure";
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /required check/
  );
});

test("unexpected blocker fails", () => {
  const evidence = alphaEvidence();
  evidence.issues.push({
    number: 99,
    state: "open",
    url: "https://github.com/example/openclaw-os/issues/99"
  });
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /unexpected open release blocker/
  );
});

test("incomplete blocker snapshot fails", () => {
  const evidence = alphaEvidence();
  evidence.issues = evidence.issues.filter((issue) => issue.number !== 14);
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /snapshot is incomplete/
  );
});

test("contradictory blocker snapshot fails", () => {
  const evidence = alphaEvidence();
  evidence.issues.push({
    number: 14,
    state: "closed",
    url: "https://github.com/example/openclaw-os/issues/14"
  });
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /duplicates/
  );
});

test("waiver fails", () => {
  const evidence = alphaEvidence();
  evidence.waivers.push("skip clean install");
  assert.throws(() => validateEvidence(policy, evidence, now), /waivers/);
});

test("stale evidence fails", () => {
  const evidence = alphaEvidence();
  evidence.generatedAt = "2026-08-14T00:00:00Z";
  assert.throws(() => validateEvidence(policy, evidence, now), /stale/);
});

test("self-reported soak is rejected", () => {
  const evidence = alphaEvidence();
  evidence.soakHours = 999;
  assert.throws(() => validateEvidence(policy, evidence, now), /derived/);
});

test("mutable or undigested evidence is rejected", () => {
  const evidence = alphaEvidence();
  evidence.evidence[0].url = "https://example.com/report";
  assert.throws(() => validateEvidence(policy, evidence, now), /immutable GitHub/);
});

test("approval after evidence generation fails", () => {
  const evidence = alphaEvidence();
  evidence.approvals[0].approvedAt = "2026-08-16T11:50:00Z";
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /approval timestamp/
  );
});

test("blank release-note values fail", () => {
  const evidence = alphaEvidence();
  evidence.releaseNotes.rollbackProcedure = "   ";
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /release notes section is missing/
  );
});
