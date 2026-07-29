# Migration and rollback

The initial extraction preserves source history from the former downstream
repository. Generic paths were filtered without rewriting their contents, then
module/import paths and packaging metadata were changed in one extraction
commit.

## Downstream migration

1. Add this repository as the `match-platform` submodule.
2. Pin an immutable full commit SHA.
3. Change game preloads from `res://platform`, `res://operations`, and the
   embedded reference adapter to `res://match-platform/...`.
4. Point game-side Go modules at `github.com/chimerakang/match-platform/rpc`
   and use a local `replace` only for a checked-out submodule.
5. Delete the embedded generic directories in the same mechanical PR.
6. Run platform conformance, game parity, legacy/mixed transport, recovery and
   full release acceptance before promotion.

## Dependency rollback

Move only the submodule gitlink back to the previously accepted commit, restore
the matching Go dependency version, and rerun the same gates. Do not copy fixes
back into the game repository or fork the protocol.

Adapter package rollback is separate: the operations registry drains the
candidate digest and resolves new matches to the previous immutable package.
Existing matches stay pinned or recover from durable state.
