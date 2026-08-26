# Release promotion

OpenClaw OS promotes one already-built artifact through `alpha`, `beta`, and
`stable`. Promotion never rebuilds the ISO. The SHA-256 digest that passed the
required checks is the digest that must be published in every later channel.

The machine-readable policy is
[`config/release-promotion-policy.json`](../config/release-promotion-policy.json).
The validator is [`scripts/release-gate.mjs`](../scripts/release-gate.mjs).

## Validate the policy

```bash
node scripts/release-gate.mjs policy config/release-promotion-policy.json
node --test tests/release-gate.test.mjs
```

## Validate release evidence

Release evidence is a JSON document that binds the candidate ISO, source
commit, CI results, retained evidence, issue state, approvals, release notes,
and soak period to one promotion decision.

```bash
node scripts/release-gate.mjs evidence \
  config/release-promotion-policy.json \
  path/to/release-evidence.json
```

The gate fails closed when:

- the tested and promoted artifact digests differ
- the source commit does not match the artifact metadata
- required CI checks or evidence are missing
- evidence is stale or dated in the future
- the minimum soak period has not elapsed
- a required blocker is not recorded closed
- the blocker snapshot is incomplete or contradictory
- an unexpected release blocker remains open
- required approval roles are missing or approval timestamps are invalid
- release notes omit required operational information
- any waiver is present

## Channel requirements

### Alpha

Alpha is for technical evaluators. It requires a verified ISO, checksums, SBOM,
UEFI live boot, a clean VM installation, compatibility evidence, update code
rollback evidence, known limitations, and release-owner approval.

The first alpha is explicitly a lab release. Issues #6, #7, and #8 may remain
open at alpha only because their own release-impact contracts block production
signing, supported compatibility, and broadly supported update channels rather
than a checksummed lab build. They remain visible blockers and are inherited by
later promotion decisions; the alpha ships no trusted first-party OS update
feed and must describe itself as unsigned.

### Beta

Beta inherits every alpha requirement. It additionally requires a tested
upgrade from a supported prior release, base-OS recovery evidence, release
signing, security review, supported-hardware documentation, and a seven-day
soak period.

### Stable

Stable inherits every beta requirement. It additionally requires physical
clean-install and upgrade evidence, a Secure Boot tamper rejection test,
recovery and withdrawal drills, the complete hardware matrix, and a fourteen-day
soak period.

## Evidence retention

Promotion records must link to retained artifacts and test logs. The release
record must include the ISO checksum, SBOM checksum, source commit, signing
identity, tested hardware, supported upgrade paths, rollback procedure, and
known limitations.

## Alpha publication transaction

`.github/workflows/publish-alpha.yml` is the only supported alpha publication
path. It accepts exact successful Build ISO and Validate run IDs for the current
`main` commit, downloads the retained candidate instead of rebuilding it,
verifies its checksums, build manifest, package-level SBOM, installed-system
evidence, issue snapshot, release notes, tag/version identity, and derived
24-hour soak period, then creates a non-overwriting GitHub prerelease. The
workflow emits and attaches the validated release-evidence document.

Tag pushes do not build images. A tag and release are created only after the
candidate passes the publication transaction.

## Emergency withdrawal

A release must be withdrawn when its signing trust, bootability, data integrity,
security posture, or rollback path is materially compromised. Withdrawal does
not authorize rebuilding an artifact under the same version. A corrected build
receives a new version and a new digest.
