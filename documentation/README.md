# Documentation Index

Use this as a decision tree instead of reading the docs front to back.

## Start here

- I am operating an existing deployed server:
  [First Admin Session](./first-admin-session.md)
- I want the shortest deployment path on an existing NixOS host:
  [Quickstart](./quickstart.md)
- I am provisioning the machine from blank disks:
  [Install From Scratch](./install-from-scratch.md)

## I need to manage users or access

- identity model, groups, OIDC clients:
  [Kanidm Guide](./kanidm.md)
- concrete commands and TUI workflow:
  [Kanidm CLI Reference](./kanidm_cli.md)
- IMAP backup and CLI search setup:
  [Mail Archive](./mail-archive.md)
- app-by-app first-login and validation behavior:
  [Runtime Validation](./runtime-validation.md)

## I need to troubleshoot or operate the server

- deploy, rollback mindset, service checks, symptom-based debugging:
  [Operations](./operations.md)
- background SMART, ZFS, timer, and ntfy alert checks:
  [Storage Monitoring](./storage-monitoring.md)
- nightly suspend policy, wake expectations, and firmware checklist:
  [Power Management](./power-management.md)
- rebuild sequencing and post-recovery validation:
  [Restore and Recovery](./restore-and-recovery.md)
- public vs private access, NetBird DNS, Unbound expectations:
  [Networking and Access](./networking-and-access.md)
- required secrets and staged prerequisites:
  [Secrets and Prerequisites](./secrets-and-prereqs.md)

## Background reference

- [How The Stack Works](./references/how-the-stack-works.md)
- [Stack Rationale](./references/stack-rationale.md)
- [Glossary](./references/glossary.md)
