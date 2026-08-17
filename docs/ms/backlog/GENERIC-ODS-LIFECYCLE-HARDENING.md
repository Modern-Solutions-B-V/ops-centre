# Generic ODS Privileged Persistent-State Lifecycle Hardening

These findings were discovered while reviewing the QR1 corrective PR, but they
are not remediated by that PR because QR1 does not invoke these generic
dashboard/installer lifecycle paths during deployment or acceptance. They need
a separate upstream-compatible design for orchestration, stop/restart behavior
and operator UX.

## MSODS-LIFE-0001 — Rootless Ownership Repair Orchestration

Severity: P1

Affected path: `ods-host-agent.py` -> `_repair_rootless_data_ownership` ->
`lib/rootless-ownership.sh`.

QR1 invocation: not used by the EVO-X3 QR1 runbook or QR1 acceptance flow. The
QR1 host qualification uses native/rootful Docker; QR1 n8n repair is handled by
`scripts/ms-qr1-prestart-provision.sh prestart-init`.

Required future outcome: derive all writers of each repaired persistent data
path, orchestrate stop/restart for generic dashboard-driven workflows, verify
quiescence at the mutation boundary, and fail closed before helper-container
recursive ownership or mode mutation.

## MSODS-LIFE-0002 — Dashboard-Driven Langfuse Setup

Severity: P1

Affected path: dashboard/host-agent extension enable or setup ->
`extensions/services/langfuse/hooks/post_install.sh`.

QR1 invocation: QR1 invokes the Langfuse hook only from the QR1 runbook after
`writer-services`, Compose stop and `verify-quiescent` complete.

Required future outcome: design generic dashboard orchestration for stopping
all writers of `data/langfuse`, running the hook, and restarting/recreating
affected services without blocking normal non-QR1 extension setup unexpectedly.

## MSODS-LIFE-0003 — Installer Rerun Ownership Repair

Severity: P1

Affected path: generic/rootful installer rerun ownership repair for persistent
data directories.

QR1 invocation: not executed by the QR1 deploy runbook or QR1 acceptance flow.

Required future outcome: ensure installer reruns do not perform privileged
ownership repair against container-writable persistent state while capable
writers are running.

## MSODS-LIFE-0004 — Purge Quiescence

Severity: P1

Affected path: `ods purge` and related generic cleanup flows.

QR1 invocation: not executed by the QR1 deploy runbook or QR1 acceptance flow.

Required future outcome: make purge stop/verify relevant writer containers and
fail closed before privileged or destructive mutation of persistent data.

## MSODS-LIFE-0005 — Uninstall Fail-Closed Writer Termination

Severity: P1

Affected path: `ods-uninstall.sh`.

QR1 invocation: not executed by the QR1 deploy runbook or QR1 acceptance flow.

Required future outcome: ensure uninstall either terminates and verifies
writers before privileged persistent-state mutation/removal or fails closed
with clear operator guidance.
