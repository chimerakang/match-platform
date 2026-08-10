# Match Platform extraction & external-adapter roadmap

Status of extracting the generic platform out of the `chimerakang/hersir` game and
enabling external (out-of-process, non-Godot) adapters. Referenced by
[ADR 0003](adr/0003-match-platform-v3-contract.md) §9. History/provenance:
[migration-and-rollback.md](migration-and-rollback.md),
[source-attribution.md](source-attribution.md).

## Status

| # | milestone | state | where |
| --- | --- | --- | --- |
| #73 | freeze the game-agnostic contract before moving code | ✅ done | [ADR 0003](adr/0003-match-platform-v3-contract.md), `platform/match_platform_v3.gd`, `platform/match_game_adapter.gd` |
| #75 | extract the game-agnostic core | ✅ done | `platform/` core + [match-platform-core.md](match-platform-core.md) |
| #273 | adapter runtime seam + in-process parity | ✅ done | `platform/adapter_runtime*.gd`, `in_process_runtime.gd`, `platform_runtime_room.gd` + [adapter-runtime-seam.md](adapter-runtime-seam.md) |
| #271 / #274 | out-of-process adapter runtime (Adapter RPC v1) | ✅ done | [ADR 0005](adr/0005-adapter-rpc-v1.md), `rpc/runtime/` + [adapter-process-runtime.md](adapter-process-runtime.md) |
| #275 | durable journal + checkpoint recovery | ✅ done | `rpc/recovery/` + [adapter-durable-recovery.md](adapter-durable-recovery.md) |
| #276 | non-Godot reference remote adapter | ✅ done | `rpc/reference/counter/` |
| #277 | custom-protocol gateway | ✅ done | `rpc/gateway/` + [custom-protocol-gateway.md](custom-protocol-gateway.md) |
| #278 | signed, sandboxed package operations + rollout | ✅ done | `rpc/operations/` + [adapter-package-operations-runbook.md](adapter-package-operations-runbook.md) |
| — | operations SDK (Godot): packaging, health/metrics, metadata, auth | ✅ done | `operations/` + [operations-sdk.md](operations-sdk.md) |
| — | first-party reference game validating the platform end to end | ✅ done | [`games/neon-shooter`](../games/neon-shooter) |

## What "done" means here

The reference deployment builds and runs, and all conformance passes, **without any
downstream game source**: `tests/run_godot_conformance.sh` (core, V3 contract,
reference adapter, operations SDK) and `tests/run_adapter_rpc_conformance.sh`
(RPC ABI, process runtime, recovery, packaging, gateway). The game-agnostic
boundary is enforced permanently by the directory scan in
`tests/platform_core_test.gd`.

## Deliberately out of scope for V3.0

Per [ADR 0003](adr/0003-match-platform-v3-contract.md) §D8, the frozen V3.0
contract does **not** promise cross-process live migration of an already-running
match, nor any client-facing admin/auth API beyond the operations service surface.
Those remain future work; the contracts above are versioned independently (see
[VERSIONING.md](../VERSIONING.md)) so they can advance without a client-protocol
break.
