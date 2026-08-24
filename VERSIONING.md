# Versioning policy

Repository releases use SemVer, and the release major MUST equal the supported
Client Protocol major. Client Protocol V3 is therefore released as Match
Platform `3.x.y`; there is no separate `0.x` product-version namespace.

- Patch (`3.0.x`): fixes that preserve Client Protocol V3, Adapter RPC v1 and SDK behavior.
- Minor (`3.x.0`): backward-compatible capabilities, SDKs, runtimes or operations.
- Major (`4.0.0`): Client Protocol V4 and its incompatible public contract. An
  artifact-layout break that requires all consumers to migrate also requires the
  next protocol/repository major, even if the envelope changes only minimally.

Adapter RPC, adapter package, codec and content versions remain independent.
The historical protobuf package name
`hersir.adapter.rpc.v1` is retained as a frozen wire ABI; it does not imply a
dependency on the downstream game.

Release tags are immutable. Consumers pin both a tag for human review and its
full commit SHA for resolution. A consumer MUST verify that the tag major, the
`VERSION` file, `MatchPlatformV3.PLATFORM_VERSION_MAJOR`, and
`MatchPlatformV3.ENVELOPE_VERSION` agree.
