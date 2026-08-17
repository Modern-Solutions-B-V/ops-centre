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

No privileged filesystem mutation may occur against an MS Ops Centre data path
while a container capable of writing that path is running.

Privileged initialization or repair must occur against quiescent state.
Runtime validation must be read-only. Post-start refresh operations must not
silently introduce privileged filesystem repair.

Quiescence must be enforced by orchestration and independently at each
MS-controlled privileged mutation boundary. A supported alternate caller, such
as host-agent invoking a setup hook directly, must not be able to bypass the
gate by skipping the normal runbook sequence.

The quiescence invariant is MS security policy. Orchestration may be
deployment-specific, but the enforcement primitive used by shared ODS lifecycle
hooks must be deployment-neutral: it accepts target persistent path(s), derives
writers from the active Compose model, and must not depend on QR1-only compose
flags, profiles or disabled template filenames.

For QR1, the quiescence gate is derived from rendered Compose writable bind
mounts that intersect the persistent data trees being repaired, including
`data/n8n`, `data/persona` and `data/langfuse`.

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
- Runbooks must present one authoritative repair path: stop derived writers,
  verify quiescence, then run the reviewed helper or hook. Manual chown/chmod/rm
  recovery against container-writable MS data must not bypass that sequence.
- Privileged helpers and hooks must fail closed themselves if quiescence has
  not been proven, even when a caller normally performs the same check first.

## Rejected Approach

Modern Solutions rejects continuing to solve each race using increasingly
complex pathname checks, symlink pre-scans and one-off TOCTOU mitigations while
writers remain live.

Pre-scan and mutation are different moments in time. Container-writable paths
can change between those moments, and root pathname resolution creates recurring
attack variants. The added complexity itself becomes a security risk because it
is difficult to audit and easy to regress.

## Future Rule

This decision applies beyond n8n and Hermes. Any future MS Ops Centre component
requiring privileged mutation of container-writable persistent state must follow
the same quiescent-state model unless explicitly superseded by another reviewed
MS decision.
