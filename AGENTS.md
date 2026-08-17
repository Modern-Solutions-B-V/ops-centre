MS OPS CENTRE AGENT RULES

1. Read docs/ms before changing anything.
2. Never work directly on ms/main.
3. One task = one branch = one worktree.
4. Never share a write-enabled worktree with another agent.
5. Classify every behavioral change:
   CONFIGURE / EXTEND / CORE CHANGE / REJECT.
6. Prefer CONFIGURE > EXTEND > CORE CHANGE.
7. CORE CHANGE requires explicit justification.
8. Do not expose secrets in prompts, logs, commits or screenshots.
9. Do not enable email send, Jira write, client-system writes, root/sudo,
   production secrets or unrestricted egress unless the task explicitly states
   that the human owner approved the permission.
10. Local-only/confidential routes must never silently fall back externally.
11. Every behavioral/config/runtime/policy/security/integration change MUST update:
    docs/ms/ODS-MS-CHANGELOG.md
    in the same commit/PR.
12. Include exact tests and rollback instructions in the changelog entry.
13. Do not approve your own implementation.
14. Do not merge PRs unless explicitly authorised.
15. Preserve upstream ODS mergeability.
16. For MS Ops Centre QR1 deployment, repair and acceptance paths, never
    perform privileged mutation of container-writable persistent state while a
    writer container is running. Require quiescent state or an explicitly
    reviewed alternative architecture. Runtime acceptance checks must be
    read-only. See docs/ms/decisions/QR1-QUIESCENT-PRIVILEGED-PROVISIONING.md.
