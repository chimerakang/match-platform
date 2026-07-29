# Versioning policy

Repository releases use SemVer.

- Patch: fixes that preserve Client Protocol V3, Adapter RPC v1 and SDK behavior.
- Minor: backward-compatible capabilities, SDKs, runtimes or operations.
- Major: an incompatible public contract or artifact-layout change.

Client Protocol, Adapter RPC, adapter package, codec and content versions remain
independent. The historical protobuf package name
`hersir.adapter.rpc.v1` is retained as a frozen wire ABI; it does not imply a
dependency on the downstream game.

Release tags are immutable. Consumers pin both a tag for human review and its
full commit SHA for resolution.
