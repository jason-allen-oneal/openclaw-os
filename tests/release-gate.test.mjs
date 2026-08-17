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
    soakHours: 24,
    artifact: {
      name: "openclaw-os-0.1.0-amd64.iso",
      digestAlgorithm: "sha256",
      testedDigest: "b".repeat(64),
      promotedDigest: "b".repeat(64),
      sourceCommit: "a".repeat(40)
    },
    checks: { validate: "success", "build-amd64": "success" },
    evidence: [
      "artifact-manifest",
      "checksums",
      "sbom",
      "uefi-live-boot",
      "clean-install",
      "compatibility-manifest",
      "update-code-rollback",
      "known-limitations"
    ],
    closedIssues: [6, 7, 8, 12, 13],
    openBlockers: [9, 10, 11, 14],
    approvals: [
      {
        role: "release-owner",
        login: "maintainer",
        approvedAt: "2026-08-16T11:30:00Z"
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
  evidence.openBlockers = evidence.openBlockers.filter((issue) => issue !== 14);
  evidence.closedIssues.push(14);
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
  evidence.checks.validate = "failure";
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /required check/
  );
});

test("unexpected blocker fails", () => {
  const evidence = alphaEvidence();
  evidence.openBlockers.push(99);
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /unexpected open release blocker/
  );
});

test("incomplete blocker snapshot fails", () => {
  const evidence = alphaEvidence();
  evidence.openBlockers = evidence.openBlockers.filter((issue) => issue !== 14);
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /snapshot is incomplete/
  );
});

test("contradictory blocker snapshot fails", () => {
  const evidence = alphaEvidence();
  evidence.closedIssues.push(14);
  assert.throws(
    () => validateEvidence(policy, evidence, now),
    /both open and closed/
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
