# Match Platform

Engine-neutral contracts and runtimes for authoritative multiplayer games.

This repository owns:

- Client Protocol V3 envelopes and the Godot platform core;
- Adapter RPC v1, generated Go/Python bindings and conformance fixtures;
- supervised process runtime, durable recovery and package operations;
- custom-protocol gateway SDK;
- standalone counter-game reference adapters.

Game rules, presentation, content and game-specific codecs belong in downstream
repositories. The reference deployment builds and runs without downstream game
source.

## Quick verification

```sh
bash tests/run_adapter_rpc_conformance.sh
bash tests/run_godot_conformance.sh
```

The RPC module is imported as:

```text
github.com/chimerakang/match-platform/rpc
```

Downstream Godot projects may pin this repository as a submodule and preload
resources below `match-platform/platform`, `match-platform/operations` and
`match-platform/adapters/reference`.

See [support and ownership](SUPPORT.md), [versioning](VERSIONING.md), and the
[migration/rollback runbook](docs/migration-and-rollback.md).
