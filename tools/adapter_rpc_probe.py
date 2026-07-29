#!/usr/bin/env python3
"""Black-box Adapter RPC v1 endpoint conformance probe."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import grpc

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "rpc" / "gen" / "python"))

from adapter.v1 import adapter_pb2 as pb  # noqa: E402
from adapter.v1 import adapter_pb2_grpc as pb_grpc  # noqa: E402


class ConformanceError(RuntimeError):
    pass


def _require_ok(meta: pb.ResponseMeta, operation: str) -> None:
    if meta.code != pb.STATUS_OK:
        raise ConformanceError(
            f"{operation} returned {pb.StatusCode.Name(meta.code)}: {meta.detail}"
        )


def probe_endpoint(endpoint: str, timeout: float = 5.0) -> dict[str, object]:
    deadline_ms = int((time.time() + timeout) * 1000)
    with grpc.insecure_channel(endpoint) as channel:
        stub = pb_grpc.AdapterServiceStub(channel)
        negotiated = stub.Negotiate(
            pb.NegotiateRequest(
                client_name="hersir-rpc-v1-conformance",
                supported_protocols=[pb.ProtocolVersion(major=1, minor=0)],
                capabilities=[
                    pb.Capability(name="deduplicate_mutations", version=1)
                ],
            ),
            timeout=timeout,
        )
        _require_ok(negotiated.meta, "Negotiate")
        if negotiated.selected_protocol.major != 1:
            raise ConformanceError("endpoint selected an incompatible protocol major")
        limits = negotiated.limits
        if min(
            limits.max_request_bytes,
            limits.max_response_bytes,
            limits.max_opaque_payload_bytes,
            limits.max_advance_ticks,
            limits.max_events_per_drain,
        ) <= 0:
            raise ConformanceError("endpoint returned incomplete or zero negotiated limits")

        health = stub.Health(
            pb.HealthRequest(
                protocol=negotiated.selected_protocol,
                request_id=1,
                deadline_unix_ms=deadline_ms,
            ),
            timeout=timeout,
        )
        _require_ok(health.meta, "Health")
        if health.status != pb.SERVING:
            raise ConformanceError("endpoint is not serving")

        descriptor = stub.GetDescriptor(
            pb.GetDescriptorRequest(
                protocol=negotiated.selected_protocol,
                request_id=2,
                deadline_unix_ms=deadline_ms,
            ),
            timeout=timeout,
        )
        _require_ok(descriptor.meta, "GetDescriptor")
        package = descriptor.descriptor
        if not package.game_id or not package.adapter_version or package.tick_rate <= 0:
            raise ConformanceError("endpoint returned an incomplete package descriptor")
        if not package.content_versions or not package.content_hashes or not package.codec_ids:
            raise ConformanceError("endpoint descriptor has no content or codec identity")

        slots = stub.GetSlotDescriptors(
            pb.GetSlotDescriptorsRequest(
                protocol=negotiated.selected_protocol,
                request_id=3,
                deadline_unix_ms=deadline_ms,
            ),
            timeout=timeout,
        )
        _require_ok(slots.meta, "GetSlotDescriptors")
        # Slot bytes are intentionally not decoded. Their codec and byte length are
        # sufficient for this language-neutral boundary probe.
        for slot in slots.slots:
            if not slot.codec_id or len(slot.value) > limits.max_opaque_payload_bytes:
                raise ConformanceError("slot descriptor violates negotiated payload limits")

        return {
            "protocol": f"{negotiated.selected_protocol.major}."
            f"{negotiated.selected_protocol.minor}",
            "game_id": package.game_id,
            "adapter_version": package.adapter_version,
            "tick_rate": package.tick_rate,
            "slot_count": len(slots.slots),
            "adapter_instance_id": health.meta.adapter_instance_id,
            "adapter_epoch": health.meta.adapter_epoch,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True, help="host:port")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    result = probe_endpoint(args.endpoint, args.timeout)
    print(
        "PASS: Adapter RPC v1 endpoint "
        f"{args.endpoint} game={result['game_id']} protocol={result['protocol']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
