# Privileged Provisioning Requires Quiescent Container-Writable State

Date: 2026-08-17

Status: Accepted

## Context

During first EVO-X3 QR1 qualification, clean-host provisioning exposed two
bind-mount defects: Hermes persona generation was missing before Compose
evaluated `data/persona/SOUL.md`, and `data/n8n` ownership was wrong for the
effective n8n container UID/GID.

Subsequent hardening introduced privileged recursive filesystem operations
against paths writable by running containers. Independent Claude Code and
GitHub Codex reviews repeatedly identified TOCTOU, symlink and path
replacement variants. That review history demonstrated that pathname hardening
alone is the wrong security boundary for privileged repair.

## Decision

Binding scope for this decision: MS Ops Centre QR1 deployment, repair and
acceptance paths.

Within that QR1 scope, no privileged filesystem mutation may occur against an
MS Ops Centre data path while a container capable of writing that path is
running.

Privileged initialization or repair must occur against quiescent state.
Runtime validation must be read-only. Post-start refresh operations must not
silently introduce privileged filesystem repair.

Broader principle: quiescence before privileged mutation is the preferred MS
security pattern. Non-claim: this QR1 decision does not assert that every
generic or upstream ODS install, extension setup, rootless repair, purge or
uninstall path currently implements the pattern. Generic gaps discovered while
reviewing this PR are tracked separately and must not be treated as QR1
acceptance blockers unless QR1 invokes that path.

For QR1, the quiescence gate is derived from rendered Compose writable bind
mounts that intersect the persistent data trees being repaired, including
`data/n8n`, `data/persona` and `data/langfuse`. QR1 mutation-boundary checks
must use the canonical complete QR1 Compose model; caller-supplied overrides
must not be able to remove base services or otherwise scope down writer
discovery.

## Consequences

- Repair uses an explicit stop -> repair -> start lifecycle where repair is
  required.
- Privileged operations are exceptional and operator-visible.
- Runtime checks never mutate state.
- TOCTOU and symlink attack surfaces are reduced because writers are stopped
  before privileged mutation.
- Rollback and audit evidence are cleaner because repair is a deliberate
  lifecycle phase.
- Operators take on slightly more sequencing in exchange for a simpler trust
  boundary.
- The QR1 runbook must present one authoritative repair path: stop derived writers,
  verify quiescence, then run the reviewed helper or hook. Manual chown/chmod/rm
  recovery against container-writable MS data must not bypass that sequence.
- Generic ODS lifecycle hardening found during review requires separate design
  and orchestration before shared dashboard-driven flows can enforce the same
  pattern.

## Rejected Approach

Modern Solutions rejects continuing to solve each race using increasingly
complex pathname checks, symlink pre-scans and one-off TOCTOU mitigations while
writers remain live.

Pre-scan and mutation are different moments in time. Container-writable paths
can change between those moments, and root pathname resolution creates recurring
attack variants. The added complexity itself becomes a security risk because it
is difficult to audit and easy to regress.

## Future Rule

This QR1 decision applies beyond n8n and Hermes inside QR1-owned deployment,
repair and acceptance paths. Any future MS Ops Centre QR component requiring
privileged mutation of container-writable persistent state must follow the same
quiescent-state model unless explicitly superseded by another reviewed MS
decision.
