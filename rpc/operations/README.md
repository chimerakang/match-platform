# Adapter Package Operations (#278)

`operations` is the operator-owned trust and rollout boundary for third-party Adapter
RPC processes.

- `Verify` checks the versioned manifest, operator allowlist, Ed25519 signature,
  immutable artifact digest, SPDX evidence, provenance and a passing vulnerability
  report.
- `LaunchPlan` produces a default-deny sandbox contract: read-only root, isolated
  loopback-only network policy, no capabilities/new privileges, optional `/tmp` tmpfs,
  masked secret/kernel paths and explicit CPU/memory/process/message/queue limits.
- `ProcessSpec` binds that plan to an absolute trusted launcher. Production
  `ProcessRuntime` refuses raw unsandboxed commands and inherited host environments.
- `Registry` performs deterministic match-stable canary selection, drain, promotion
  and rollback. Existing matches remain pinned to the package digest they started
  with.
- Audit and health/resource telemetry are partitioned by immutable digest and contain
  no opaque gameplay payload.

The JSON contract is
[`package-manifest.schema.json`](package-manifest.schema.json). Operational response
procedures are in
[`docs/adapter-package-operations-runbook.md`](../../docs/adapter-package-operations-runbook.md).

```sh
go test -race ./operations ./runtime
```
