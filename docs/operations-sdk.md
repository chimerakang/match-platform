# Operations SDK (GDScript)

The operator-facing control plane under `operations/`: package versioning &
rollout, health/metrics/admin, durable match metadata, and product identity. It
sits **beside/above** the [core mechanics](match-platform-core.md) and is **never**
on the per-frame authoritative path. Its boundary is as strict as the core's: it
never accepts checkpoints, state, events, commands, or replay.

For the out-of-process operator machinery (signed packages, canary rollout,
durable recovery) see [adapter-package-operations-runbook.md](adapter-package-operations-runbook.md)
and [adapter-durable-recovery.md](adapter-durable-recovery.md).

## Package versioning & rollout — `GamePackageRegistry`

`operations/game_package_registry.gd`. The mutable operator layer above the frozen
[`PlatformAdapterRegistry`](match-platform-core.md#registry--the-pre-seat-gate--match-factory):
it adds versioning, activation, history and rollback that the core deliberately
does not know about, then **projects the currently-active set through a fresh
`PlatformAdapterRegistry` for every negotiation** — so the pre-seat contract stays
frozen while rollout policy lives here.

| method | purpose |
| --- | --- |
| `register(adapter, activate_now=true)` | admit a new adapter *version* (validates descriptor, wraps in a local runtime, refuses duplicate version) |
| `load_file(path)` / `load_configuration(config)` | trusted `res://` manifest loading |
| `activate(game_id, version)` | make a version live (pushes the previous to history) |
| `rollback(game_id)` | pop history → previous version |
| `welcome_for` / `resolve_hello` / `create_match` / `recover_match` | negotiation pass-throughs (delegated to a freshly-projected core registry) |
| `runtime_for` / `adapter_for` / `descriptor` / `slot_descriptors` / `registered_game_ids` / `has_game` | lookups |
| `inventory()` | ordered `{game_id, adapter_version, active, content_versions, content_hashes, codec_ids}` |

Composition, not inheritance: the core registry is the frozen gate; this is the
operator wrapper that rebuilds a core registry from its active versions on demand.

## Health / metrics / admin — `MatchOperationsService`

`operations/match_operations_service.gd`, constructed with `(packages, matches)`
(a package registry + a metadata store). JSON-ready; the V3.2 "operations service"
deferred in [ADR 0003](adr/0003-match-platform-v3-contract.md) §9.

| method | returns |
| --- | --- |
| `health()` | `{status: ok|degraded, active_packages, known_matches}` |
| `metrics(arena_telemetry)` | per match, split into a **platform** bag (whitelisted fields) and an opaque **adapter** bag (`game_metrics`), keyed by `match_id / game_id / adapter_version` |
| `admin_inventory()` | `{packages, matches}` |
| `activate_package(game_id, version)` / `rollback_package(game_id)` | delegate to the package registry |

Metrics partitioning is the boundary in action: one game's opaque metrics can never
leak into another's, and platform metrics are an explicit allow-list.

## Durable match metadata — `MatchMetadataStore`

`operations/match_metadata_store.gd` (abstract) + `in_memory_match_metadata_store.gd`
(local/CI). **Gameplay payloads are forbidden** — only operator identity/lifecycle
fields (`ALLOWED_FIELDS`: match_id, game_id, adapter_version, content_version,
content_hash, codec_ids, status, created/updated/ended timestamps).

- `validate_record(record)` rejects any non-allowed or missing-required field.
- `upsert` / `get_match` / `list_matches(filters={})` — base no-ops; the in-memory
  provider stamps `created_at_unix` / `updated_at_unix` and supports filtered,
  ordered listing. A durable provider overrides these.

## Product identity — `AuthIdentityVerifier`

`operations/auth_identity_verifier.gd` (abstract) +
`in_memory_auth_identity_verifier.gd` (local/CI). The **product-auth** boundary for
`join.auth_context` — distinct from the session resume token (the three-identities
rule of [ADR 0003](adr/0003-match-platform-v3-contract.md) §7.2). Session recovery
tokens never enter here.

- `verify(auth_context, request_context={})` → `{ok, subject, claims, provider}` or
  `unauthorized`.
- The in-memory provider does bearer-token lookup, or (if `allow_anonymous`) mints
  `anonymous:<peer_id>` from the **server-owned** `request_context.peer_id`,
  deliberately ignoring any client-supplied identity/reconnect fields. It is
  injectable so production swaps it in without touching lobby/session/adapter code.

## How it fits

```mermaid
flowchart TB
    OP["MatchOperationsService<br/>(health / metrics / admin)"] --> GPR["GamePackageRegistry<br/>(versions, activate, rollback)"]
    OP --> MS["MatchMetadataStore"]
    GPR -->|projects per negotiation| REG["PlatformAdapterRegistry (frozen gate)"]
    AUTH["AuthIdentityVerifier"] -. join.auth_context .-> HOST["lobby / host"]
    HOST --> REG
```

Everything here is optional to a bare integrator (neon-shooter wires the core
registry directly), but it is what a real deployment uses to roll adapter versions,
answer health/metrics probes, persist match metadata, and authenticate players —
all without any game concept entering the platform.
