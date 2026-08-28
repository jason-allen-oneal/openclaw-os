#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

function fail(message) {
  throw new Error(message);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    fail(`cannot read JSON ${path}: ${error.message}`);
  }
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function uniqueStrings(value, label) {
  assert(
    Array.isArray(value) &&
      value.every(
        (item) => typeof item === "string" && item.trim().length > 0
      ),
    `${label} must be a non-empty string array`
  );
  assert(new Set(value).size === value.length, `${label} contains duplicates`);
  return value;
}

function uniqueIntegers(value, label) {
  assert(
    Array.isArray(value) &&
      value.every((item) => Number.isInteger(item) && item > 0),
    `${label} must be a positive integer array`
  );
  assert(new Set(value).size === value.length, `${label} contains duplicates`);
  return value;
}

export function validatePolicy(policy) {
  assert(
    policy && typeof policy === "object" && !Array.isArray(policy),
    "policy must be an object"
  );
  assert(policy.schemaVersion === 1, "unsupported policy schemaVersion");
  assert(
    policy.artifactIdentity?.digestAlgorithm === "sha256",
    "artifact digest must be sha256"
  );
  assert(
    policy.artifactIdentity?.rebuildOnPromotion === false,
    "promotion must not rebuild artifacts"
  );
  assert(
    policy.artifactIdentity?.requireSameDigestAcrossChannels === true,
    "promotion must preserve artifact identity"
  );
  assert(
    policy.evidence?.waiversAllowed === false,
    "release waivers must remain disabled"
  );
  assert(
    Number.isInteger(policy.evidence?.maximumAgeHours) &&
      policy.evidence.maximumAgeHours > 0,
    "maximum evidence age must be positive"
  );

  const names = ["alpha", "beta", "stable"];
  for (const name of names) {
    assert(policy.channels?.[name], `missing ${name} channel`);
  }
  assert(!policy.channels.alpha.inherits, "alpha must not inherit another channel");
  assert(policy.channels.beta.inherits === "alpha", "beta must inherit alpha");
  assert(policy.channels.stable.inherits === "beta", "stable must inherit beta");

  let previousSoak = 0;
  for (const name of names) {
    const channel = policy.channels[name];
    assert(
      Number.isInteger(channel.minimumSoakHours) &&
        channel.minimumSoakHours >= previousSoak,
      `${name} soak period must be cumulative`
    );
    previousSoak = channel.minimumSoakHours;
    uniqueStrings(channel.requiredEvidence, `${name}.requiredEvidence`);
    uniqueIntegers(channel.requiredClosedIssues, `${name}.requiredClosedIssues`);
    uniqueIntegers(channel.allowedOpenBlockers, `${name}.allowedOpenBlockers`);
    uniqueStrings(channel.requiredApprovalRoles, `${name}.requiredApprovalRoles`);
    if (name === "alpha") {
      uniqueStrings(channel.requiredChecks, "alpha.requiredChecks");
    }
  }

  uniqueStrings(
    policy.releaseNotes?.requiredSections,
    "releaseNotes.requiredSections"
  );
  assert(
    policy.withdrawal?.required === true,
    "emergency withdrawal must be required"
  );
  uniqueStrings(policy.withdrawal?.reasons, "withdrawal.reasons");
  return policy;
}

function resolvedChannel(policy, channelName) {
  assert(
    ["alpha", "beta", "stable"].includes(channelName),
    `unknown channel: ${channelName}`
  );
  const order = ["alpha", "beta", "stable"];
  const target = order.indexOf(channelName);
  const merged = {
    requiredChecks: [],
    requiredEvidence: [],
    requiredClosedIssues: [],
    allowedOpenBlockers: [],
    requiredApprovalRoles: [],
    minimumSoakHours: 0
  };

  for (let index = 0; index <= target; index += 1) {
    const channel = policy.channels[order[index]];
    for (const key of [
      "requiredChecks",
      "requiredEvidence",
      "requiredClosedIssues",
      "requiredApprovalRoles"
    ]) {
      for (const value of channel[key] ?? []) {
        if (!merged[key].includes(value)) merged[key].push(value);
      }
    }
    merged.allowedOpenBlockers = [...(channel.allowedOpenBlockers ?? [])];
    merged.minimumSoakHours = channel.minimumSoakHours;
  }

  return merged;
}

function validateReleaseNoteValue(value, section) {
  if (Array.isArray(value)) {
    assert(
      value.length > 0 &&
        value.every(
          (item) => typeof item === "string" && item.trim().length > 0
        ),
      `release notes section is missing: ${section}`
    );
    return;
  }
  assert(
    typeof value === "string" && value.trim().length > 0,
    `release notes section is missing: ${section}`
  );
}

export function validateEvidence(policyInput, evidence, now = new Date()) {
  const policy = validatePolicy(policyInput);
  assert(
    evidence && typeof evidence === "object" && !Array.isArray(evidence),
    "evidence must be an object"
  );
  assert(evidence.schemaVersion === 1, "unsupported evidence schemaVersion");
  assert(now instanceof Date && !Number.isNaN(now.getTime()), "now is invalid");

  const channel = resolvedChannel(policy, evidence.channel);
  assert(
    /^[a-f0-9]{40}$/.test(evidence.sourceCommit ?? ""),
    "sourceCommit must be a full SHA-1 commit ID"
  );
  assert(
    evidence.artifact?.digestAlgorithm === "sha256",
    "artifact digest algorithm must be sha256"
  );
  assert(
    /^[a-f0-9]{64}$/.test(evidence.artifact?.testedDigest ?? ""),
    "testedDigest must be SHA-256"
  );
  assert(
    evidence.artifact.testedDigest === evidence.artifact.promotedDigest,
    "promoted artifact digest differs from tested artifact"
  );
  assert(
    evidence.artifact.sourceCommit === evidence.sourceCommit,
    "artifact source commit differs from evidence commit"
  );
  assert(
    Number.isInteger(evidence.artifact.actionsArtifact?.id) &&
      evidence.artifact.actionsArtifact.id > 0 &&
      evidence.artifact.actionsArtifact.name === "openclaw-os-amd64" &&
      evidence.artifact.actionsArtifact.expired === false &&
      /^sha256:[a-f0-9]{64}$/.test(
        evidence.artifact.actionsArtifact.archiveDigest ?? ""
      ) &&
      evidence.artifact.actionsArtifact.workflowRunHeadSha ===
        evidence.sourceCommit,
    "Actions artifact identity is invalid"
  );
  assert(
    typeof evidence.artifact.name === "string" &&
      evidence.artifact.name.endsWith(".iso"),
    "artifact name must identify an ISO"
  );

  const generatedAt = new Date(evidence.generatedAt);
  assert(!Number.isNaN(generatedAt.getTime()), "generatedAt must be an ISO timestamp");
  const ageHours = (now.getTime() - generatedAt.getTime()) / 3_600_000;
  assert(
    ageHours >= 0 && ageHours <= policy.evidence.maximumAgeHours,
    "release evidence is stale or from the future"
  );
  const builtAt = new Date(evidence.artifact?.builtAt);
  assert(!Number.isNaN(builtAt.getTime()), "artifact builtAt must be an ISO timestamp");
  assert(
    builtAt.getTime() <= generatedAt.getTime(),
    "artifact builtAt is after evidence generation"
  );
  const soakHours = (now.getTime() - builtAt.getTime()) / 3_600_000;
  assert(soakHours >= channel.minimumSoakHours, "minimum soak period has not elapsed");
  assert(
    evidence.soakHours === undefined,
    "soakHours must be derived from artifact builtAt"
  );
  assert(
    Array.isArray(evidence.waivers) && evidence.waivers.length === 0,
    "release waivers are not permitted"
  );

  for (const check of channel.requiredChecks) {
    const record = evidence.checks?.[check];
    assert(
      record?.status === "success" &&
        record?.headSha === evidence.sourceCommit &&
        /^https:\/\/github\.com\/[^/]+\/[^/]+\/actions\/runs\/[0-9]+$/.test(
          record?.runUrl ?? ""
        ),
      `required check did not pass: ${check}`
    );
  }

  assert(Array.isArray(evidence.evidence), "evidence.evidence must be an array");
  const evidenceNames = uniqueStrings(
    evidence.evidence.map((record) => record?.name),
    "evidence names"
  );
  for (const record of evidence.evidence) {
    assert(
      /^https:\/\/github\.com\/[^/]+\/[^/]+\/(actions\/runs\/[0-9]+|releases\/tag\/[^/]+)(?:#.*)?$/.test(
        record?.url ?? ""
      ),
      `evidence URL is not immutable GitHub evidence: ${record?.name ?? "unknown"}`
    );
    assert(
      /^[a-f0-9]{64}$/.test(record?.sha256 ?? ""),
      `evidence digest is invalid: ${record?.name ?? "unknown"}`
    );
  }
  for (const item of channel.requiredEvidence) {
    assert(evidenceNames.includes(item), `missing required evidence: ${item}`);
  }

  assert(Array.isArray(evidence.issues), "evidence.issues must be an array");
  const issueNumbers = uniqueIntegers(
    evidence.issues.map((issue) => issue?.number),
    "evidence issue numbers"
  );
  const closedIssues = evidence.issues
    .filter((issue) => issue?.state === "closed")
    .map((issue) => issue.number);
  const openBlockers = evidence.issues
    .filter((issue) => issue?.state === "open")
    .map((issue) => issue.number);
  for (const issue of evidence.issues) {
    assert(
      issue.state === "open" || issue.state === "closed",
      `invalid issue state: #${issue.number}`
    );
    assert(
      /^https:\/\/github\.com\/[^/]+\/[^/]+\/issues\/[0-9]+$/.test(issue.url ?? ""),
      `invalid issue URL: #${issue.number}`
    );
  }
  for (const issue of channel.requiredClosedIssues) {
    assert(
      closedIssues.includes(issue),
      `required issue is not recorded closed: #${issue}`
    );
  }

  for (const issue of openBlockers) {
    assert(
      channel.allowedOpenBlockers.includes(issue),
      `unexpected open release blocker: #${issue}`
    );
    assert(
      !closedIssues.includes(issue),
      `release blocker is recorded both open and closed: #${issue}`
    );
  }
  for (const issue of channel.allowedOpenBlockers) {
    assert(
      openBlockers.includes(issue) || closedIssues.includes(issue),
      `release-blocker snapshot is incomplete: #${issue}`
    );
  }
  const expectedIssueNumbers = new Set([
    ...channel.requiredClosedIssues,
    ...channel.allowedOpenBlockers
  ]);
  assert(
    issueNumbers.length === expectedIssueNumbers.size &&
      issueNumbers.every((issue) => expectedIssueNumbers.has(issue)),
    "release-blocker snapshot contains unexpected or missing issues"
  );

  assert(Array.isArray(evidence.approvals), "evidence.approvals must be an array");
  const roles = uniqueStrings(
    evidence.approvals.map((approval) => approval?.role),
    "evidence.approval roles"
  );
  for (const role of channel.requiredApprovalRoles) {
    assert(roles.includes(role), `missing approval role: ${role}`);
  }
  for (const approval of evidence.approvals) {
    assert(
      typeof approval.login === "string" && approval.login.trim().length > 0,
      "approval login is required"
    );
    const observedAt = new Date(approval.observedAt);
    assert(!Number.isNaN(observedAt.getTime()), "approval observation timestamp is invalid");
    assert(
      observedAt.getTime() <= generatedAt.getTime() &&
        observedAt.getTime() <= now.getTime(),
      "approval observation is after the evidence timestamp or in the future"
    );
    assert(
      approval.method === "protected-environment" &&
        approval.environment === "alpha-release" &&
        approval.timestampSource === "protected-job-start" &&
        Number.isInteger(approval.jobId) &&
        approval.jobId > 0 &&
        approval.runAttempt === 1 &&
        /^https:\/\/github\.com\/[^/]+\/[^/]+\/actions\/runs\/[0-9]+$/.test(
          approval.runUrl ?? ""
        ),
      "release approval must come from a protected GitHub environment"
    );
  }

  assert(
    evidence.releaseNotes &&
      typeof evidence.releaseNotes === "object" &&
      !Array.isArray(evidence.releaseNotes),
    "releaseNotes must be an object"
  );
  for (const section of policy.releaseNotes.requiredSections) {
    validateReleaseNoteValue(evidence.releaseNotes[section], section);
  }

  return true;
}

function usage() {
  console.error(
    "Usage: release-gate.mjs policy <policy.json> | evidence <policy.json> <evidence.json>"
  );
  process.exit(2);
}

const invokedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (invokedDirectly) {
  try {
    const [command, policyPath, evidencePath] = process.argv.slice(2);
    if (command === "policy" && policyPath && !evidencePath) {
      validatePolicy(readJson(policyPath));
      console.log("Release promotion policy is valid.");
    } else if (command === "evidence" && policyPath && evidencePath) {
      validateEvidence(readJson(policyPath), readJson(evidencePath));
      console.log("Release evidence satisfies the promotion policy.");
    } else {
      usage();
    }
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}
