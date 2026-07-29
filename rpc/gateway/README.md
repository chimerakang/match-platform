# Custom Protocol Gateway SDK (#277)

`gateway` is the supported boundary for an existing game's wire protocol. A
game-owned `Translator` maps custom client frames to frozen Client Protocol V3
envelopes and maps V3 server envelopes back to the custom protocol. The SDK validates
the result, bounds both directions, applies admission limits, preserves delivery
classes and emits protocol-neutral telemetry.

The SDK does not import or modify Godot platform core and does not call Adapter RPC
directly. In production, a deployment-specific transport sends the translated V3
envelopes to the ordinary V3 endpoint. The black-box reference fixture uses the same
V3 boundary and the out-of-process counter adapter to keep the test hermetic.

See [the deployment and implementation guide](../../docs/custom-protocol-gateway.md)
and [`reference`](reference) for a deliberately non-V3 counter protocol.
