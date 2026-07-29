# Adapter Package Security and Rollout Runbook (#278)

## Trust and installation

Clients never submit a binary, digest, endpoint, package version or rollout selector.
They submit only the frozen game identity in V3. Operators install an immutable
package before it can enter the registry:

1. build the adapter in a controlled CI identity;
2. emit its SHA-256 digest, SPDX 2.x SBOM, SLSA-style provenance and vulnerability
   report;
3. require zero critical/high findings and make every evidence file digest-addressed;
4. sign the canonical manifest with an Ed25519 release key;
5. configure the signer public key and exact `package_id` in the operator allowlist;
6. call `Verify`, materialize the returned `LaunchPlan`, then call `Install`.

Relative manifest paths must stay inside the package root. Symlinks, path traversal,
digest/signature mismatch, incomplete compatibility identity, unsafe sandbox settings
and failed vulnerability policy are rejected before installation.

## Process and secret boundary

Production `ProcessRuntime` accepts only a process marked as an operations-verified
sandbox launcher and refuses host-environment inheritance. It injects only endpoint,
instance id, epoch and workload identity, plus explicitly verified non-secret package
configuration.

The trusted Linux/OCI launcher must enforce the launch plan:

- read-only root filesystem and no host mounts;
- only an optional private `/tmp` tmpfs is writable;
- a loopback-only network policy, with no outbound or public listener; only the
  supervisor-owned local mTLS endpoint is reachable;
- no ambient/effective/permitted capabilities and `no_new_privileges`;
- masked `/run/secrets`, sensitive `/proc`/`sys` paths and no service-account mount;
- CPU quota, memory hard limit, PID limit and bounded RPC messages/queue;
- loopback-only Adapter RPC over mutual TLS to the platform workload identity.

The adapter receives workload certificate file paths only from the launcher's
read-only `/run/hersir-tls` identity mount. It receives no cloud credentials, registry
token, signing key, database credential or gateway/client secret.

## Canary, drain and rollback

`Activate(game, digest, percent)` selects a candidate by a stable hash of the
platform-owned game/match identity. The client cannot influence a binary or endpoint.
The first resolved package digest is pinned for the match:

- canary percentage changes affect only new matches;
- `Drain` stops new selection while existing pins continue;
- `Promote` makes the candidate stable for new matches;
- `Rollback` removes a candidate or returns new matches to the previous stable digest;
- neither drain nor rollback migrates a live match across package/runtime identity.

Before promotion, compare per-digest health, crash-loop, resource exhaustion, latency,
queue and recovery SLOs. Exercise drain and rollback with live pinned matches.

## Incident response

### Suspected compromise

1. Remove the signer/package from the allowlist and drain every affected digest.
2. Roll back new matches to the last trusted digest; do not live-migrate matches.
3. Revoke workload certificates and terminate affected sandboxes.
4. Preserve manifest/evidence, audit records and payload-free runtime telemetry.
5. Rotate any explicitly mounted credential, rebuild from trusted source and issue a
   new digest/signature. Never reactivate the compromised digest.

### Bad release or crash loop

1. Stop canary selection or drain the promoted digest.
2. Roll back; existing healthy old-package matches remain pinned.
3. If a pinned match process crashed, recover through the durable checkpoint/journal
   only when the package accepts that checkpoint version.
4. Compare failure/resource/latency telemetry and retain the package evidence.

### Incompatible checkpoint

1. Fail closed; never reinterpret or discard the durable checkpoint silently.
2. Keep the old package available for the pinned match and drain the incompatible one.
3. Roll back new selection.
4. Require an explicit offline migration tool with source/target versions, digest,
   hash verification and reversible backup before retrying.

## Verification

```sh
cd rpc
go test -race ./operations ./runtime
```

Fixtures cover artifact/signature/SBOM/provenance/vulnerability tampering, unsafe
sandbox/environment rejection, ambient-secret scrubbing, package-isolated
crash/resource telemetry, deterministic canary, live-match pins, drain, promotion and
both canary and stable rollback.
