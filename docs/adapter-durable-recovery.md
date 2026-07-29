# Durable Adapter Recovery (#275)

`rpc/recovery` adds the durable half of the process-isolated `AdapterRuntime`. It is
game-agnostic: commands, checkpoints, results and replay remain opaque Adapter RPC v1
protobuf bytes.

## Write and recovery protocol

Each authoritative mutation follows one serialized write-ahead path:

```text
fsync prepare journal record
  → dispatch ApplyCommand / Advance
  → read post-mutation state hash
  → fsync commit record
  → atomically rename committed-watermark manifest
  → optionally save versioned checkpoint
```

The file store uses deterministic JSONL records with SHA-256 checksums. Journal appends
and checkpoint files are fsynced; manifest and compaction updates use write-temp,
fsync, rename and directory fsync. A synced commit record repairs a manifest update
interrupted before rename. An orphan checkpoint written before its manifest update is
ignored and the committed journal is replayed instead.

`Coordinator` implements the mutation/checkpoint/recovery protocol against the same
`runtime.AdapterRuntime` interface introduced by #274. After the supervisor creates a
new epoch it:

1. loads and verifies the manifest, checkpoint and journal;
2. restores the latest authoritative checkpoint;
3. verifies the checkpoint state hash;
4. replays committed entries after the checkpoint in sequence order;
5. resolves a prepared-but-uncommitted entry once on the restored state;
6. verifies every recorded post-mutation hash and adapter status.

Recovery into the same or an older adapter epoch fails closed. This prevents platform
restart from replaying onto an adapter process whose in-memory outcome is unknown.

When `CreateMatch` is called before the coordinator takes ownership,
`CoordinatorConfig.InitialRequestID` must be set to that create request id. The first
durable mutation then continues the original epoch's monotonic request sequence. A
fresh recovery epoch always starts a new request sequence.

## Identity and duplicate rules

Every journal prepare stores `(match_id, adapter_epoch, request_id, sequence,
operation, deterministic request bytes)`.

- The same epoch/request and byte-identical request returns the durable entry.
- Reusing the identity with different bytes returns `duplicate_request_mismatch`.
- A lower epoch returns `stale_epoch`.
- A non-monotonic request id returns `out_of_order`.
- A prepared request without a durable response returns `unknown_outcome` until a
  fresh-epoch recovery resolves it.

Persistence errors map to Adapter RPC v1 status codes through `recovery.StatusCode`.
No error or telemetry field includes opaque payload contents.

## Store interface and local implementation

`recovery.Store` is the production provider boundary. `FileStore` is the deterministic
local/CI implementation and uses a private SHA-256-derived directory per match. The
configured root must be on durable local storage and have one platform writer.

Retention keeps a bounded number of checkpoints and a bounded committed-entry
deduplication window. Entries newer than the checkpoint always remain replayable.

## Telemetry and budgets

Recovery telemetry is partitioned by match and reports recovery/failure counts,
replayed entries, checkpoint success/failure, last recovery duration and storage
bytes.

The CI fixture performs 100 durable mutations with a checkpoint every ten entries and
enforces:

- recovery under 500 ms;
- storage below 512 KiB;
- at most two retained checkpoints.

It also crashes at prepare-fsync, commit-fsync and checkpoint-rename boundaries,
restarts after every simulated match step, and compares every tick hash, terminal
result and replay digest with an uninterrupted run.

```sh
bash tests/run_adapter_rpc_conformance.sh
```
