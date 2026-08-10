# neon-platform-shooter

A first-party reference game on Match Platform V3: a 2–8 player, server-
authoritative platform shooter with destructible terrain. It is a complete,
tested example of a downstream game — adapter, codec, multi-arena lobby, WebSocket
host and a predicting client — and doubles as living documentation for
[docs/integration-guide.md](../../docs/integration-guide.md).

It runs entirely on the platform core: the Node authoritative server it was ported
from is **not** here. Its production deployment pipeline stays in the original game
repository; this directory is the game logic only.

## Layout

```
games/neon-shooter/
├── core.gd                 shared sim: terrain field + player physics (client & server)
├── adapters/
│   ├── neon_shooter_adapter.gd   MatchGameAdapter: rules, phases, deterministic sim, hash, replay
│   └── neon_shooter_codec.gd     JSON codec (neon.json.v1): reliability grouping + framing
├── server/
│   ├── shooter_lobby.gd    transport-agnostic multi-arena lobby + baseball rotation
│   └── server_main.gd      thin WebSocket host shell around the lobby
├── client/
│   ├── arena.gd/.tscn      Godot client scene (rendering, input, prediction)
│   ├── net_client_v3.gd    V3 client seam (hello→welcome→join→checkpoint/state/event)
│   ├── hud.gd, ai_test_server.gd, tools/
│   └── icon.svg, export_presets.cfg
└── tests/
    ├── neon_adapter_platform_test.gd   adapter driven through the real platform core (36 checks)
    ├── shooter_lobby_test.gd           seating / queue / rotation / reconnect (11 checks)
    ├── e2e_v3_client.gd + run_e2e_v3.sh  live server + client over WebSocket (5 checks)
    └── run_conformance.sh              adapter + lobby
```

## Run

From the repository root (`godot` = Godot 4.6+ headless-capable binary):

```sh
# authoritative server (WebSocket)
godot --headless --path . --script res://games/neon-shooter/server/server_main.gd

# graphical client (connects to a running server; see PS_SERVER below)
godot --path .

# tests
bash games/neon-shooter/tests/run_conformance.sh
bash games/neon-shooter/tests/run_e2e_v3.sh
```

The client's main scene is the game, so a bare `godot --path .` launches it; the
platform's conformance tests are unaffected because they run via `--script`.

## Configuration (environment variables)

| var | side | meaning | default |
| --- | --- | --- | --- |
| `PS_PORT` | server | WebSocket listen port | `2567` |
| `PS_BIND` | server | bind address (`0.0.0.0` to expose) | `127.0.0.1` |
| `PS_ARENAS` | server | number of concurrent arenas | `3` |
| `PS_SEED` | server | deterministic base seed (arena i uses `seed+i`) | `1337` |
| `PS_SERVER` | client | server URL, injected as `window.PS_SERVER` on web | fallback const |
| `PS_URL` | e2e test | server URL the headless test client dials | `ws://127.0.0.1:2567` |
| `PS_AI_TEST_SERVER` | client | `1` enables the local AI test TCP harness (off by default) | off |

## Wire protocol (opaque `payload` shapes)

The platform envelope is generic; these are the shooter's own payload bodies
carried inside V3 `command`/`state`/`event`. Client → server commands:

| `payload.kind` | fields | phase |
| --- | --- | --- |
| `input` | `seq, left, right, jump, aimX, aimY` | any (movement applied in battle) |
| `draw` | `x0, y0, x1, y1` | draw only |
| `shoot` | — | battle only |
| `weapon` | `w` (`pistol`/`shotgun`/`rocket`/`laser`) | any |
| `redraw` | — | draw only |

Server → client: `checkpoint` carries the full state (`players`, `bullets`,
terrain `field` base64, `phase`); `state` carries a replaceable `{replace: …}`
dynamic snapshot; `event` payloads use `kind` = `seat` (reliable slot/color hint),
`phase`, `stroke`/`crater` (reliable terrain edits), `kill` (droppable FX),
`queue`. See [net_client_v3.gd](client/net_client_v3.gd) for how the client
applies each.

## Rules summary

Continuous `draw → battle → results` rounds (endless by default; `rounds:N` in the
match config bounds it). Draw: paint terrain within an ink budget. Battle: move,
switch weapons, shoot; sub-stepped bullets carve terrain and damage players; rocket
splash; a spawn-guard window grants brief invincibility; frag limit or timer ends
the round. Idle slots are backfilled by deterministic bots up to `BOT_MIN_PLAYERS`
when a human is present. The lobby seats humans into free slots, queues when full,
and runs "野球賽" rotation (lowest-scoring human out, next waiter in) at each round
boundary. Everything is deterministic (seeded RNG in state), so replay and
in-process recovery reproduce the exact state hash.
