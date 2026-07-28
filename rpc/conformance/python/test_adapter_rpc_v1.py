import json
from concurrent import futures
import re
import unittest
from pathlib import Path

import grpc
from google.protobuf import json_format

from adapter.v1 import adapter_pb2 as pb
from adapter.v1 import adapter_pb2_grpc as pb_grpc
from tools.adapter_rpc_probe import probe_endpoint


FIXTURE = (
    Path(__file__).parents[1]
    / "fixtures"
    / "adapter_rpc_v1_golden.json"
)
EXPECTED_METHODS = {
    "Negotiate",
    "GetDescriptor",
    "GetSlotDescriptors",
    "ValidateMatchConfig",
    "CreateMatch",
    "RecoverMatch",
    "ValidateJoin",
    "ValidateCommand",
    "ApplyCommand",
    "Advance",
    "GetTerminalResult",
    "GetStateHash",
    "ExportReplay",
    "BuildCheckpoint",
    "BuildDelta",
    "DrainEvents",
    "GetMetrics",
    "Health",
}
ADAPTER_OPERATION_MAP = {
    "package_descriptor": "GetDescriptor",
    "slot_descriptors": "GetSlotDescriptors",
    "validate_match_config": "ValidateMatchConfig",
    "create_match": "CreateMatch",
    "recover_match": "RecoverMatch",
    "validate_join": "ValidateJoin",
    "validate_command": "ValidateCommand",
    "apply_command": "ApplyCommand",
    "advance": "Advance",
    "terminal_result": "GetTerminalResult",
    "state_hash": "GetStateHash",
    "export_replay": "ExportReplay",
    "build_checkpoint": "BuildCheckpoint",
    "build_delta": "BuildDelta",
    "drain_events": "DrainEvents",
    "metrics": "GetMetrics",
}


def negotiate(request: pb.NegotiateRequest) -> pb.NegotiateResponse:
    compatible = [version for version in request.supported_protocols if version.major == 1]
    if not compatible:
        return pb.NegotiateResponse(
            meta=pb.ResponseMeta(
                code=pb.STATUS_UNSUPPORTED_PROTOCOL,
                detail="no compatible Adapter RPC major",
                retryable=False,
            )
        )
    selected = max(compatible, key=lambda version: version.minor)
    return pb.NegotiateResponse(
        meta=pb.ResponseMeta(code=pb.STATUS_OK),
        selected_protocol=pb.ProtocolVersion(major=1, minor=selected.minor),
    )


class AdapterRpcV1ConformanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_golden_frames_round_trip_deterministically(self):
        for case in self.corpus["cases"]:
            with self.subTest(case=case["name"]):
                message_type = getattr(pb, case["message_type"])
                message = json_format.ParseDict(case["json"], message_type())
                wire = message.SerializeToString(deterministic=True)
                self.assertEqual(wire.hex(), case["canonical_hex"])
                decoded = message_type.FromString(wire)
                self.assertEqual(decoded, message)

    def test_unknown_major_is_rejected_before_dispatch(self):
        case = next(
            item for item in self.corpus["cases"]
            if item["name"] == "negotiate_unknown_major"
        )
        request = pb.NegotiateRequest.FromString(bytes.fromhex(case["canonical_hex"]))
        response = negotiate(request)
        self.assertEqual(
            pb.StatusCode.Name(response.meta.code),
            case["expected_status"],
        )
        self.assertFalse(response.meta.retryable)

    def test_generated_python_client_and_server_cover_full_surface(self):
        service = pb.DESCRIPTOR.services_by_name["AdapterService"]
        self.assertEqual({method.name for method in service.methods}, EXPECTED_METHODS)
        channel = grpc.insecure_channel("localhost:1")
        try:
            stub = pb_grpc.AdapterServiceStub(channel)
            for method in EXPECTED_METHODS:
                self.assertTrue(hasattr(stub, method))
                self.assertTrue(hasattr(pb_grpc.AdapterServiceServicer, method))
        finally:
            channel.close()

    def test_every_match_game_adapter_operation_has_an_rpc(self):
        source = (
            Path(__file__).parents[3] / "platform" / "match_game_adapter.gd"
        ).read_text(encoding="utf-8")
        operations = set(re.findall(r"^func ([a-z_]+)\(", source, re.MULTILINE))
        self.assertEqual(operations, set(ADAPTER_OPERATION_MAP))
        self.assertTrue(set(ADAPTER_OPERATION_MAP.values()).issubset(EXPECTED_METHODS))

    def test_black_box_endpoint_probe_never_decodes_game_payloads(self):
        class Endpoint(pb_grpc.AdapterServiceServicer):
            def Negotiate(self, request, context):
                return pb.NegotiateResponse(
                    meta=pb.ResponseMeta(
                        code=pb.STATUS_OK,
                        adapter_instance_id="fixture-instance",
                        adapter_epoch=7,
                    ),
                    selected_protocol=pb.ProtocolVersion(major=1),
                    limits=pb.Limits(
                        max_request_bytes=1024,
                        max_response_bytes=4096,
                        max_opaque_payload_bytes=512,
                        max_advance_ticks=60,
                        max_events_per_drain=32,
                    ),
                )

            def Health(self, request, context):
                return pb.HealthResponse(
                    meta=pb.ResponseMeta(
                        code=pb.STATUS_OK,
                        request_id=request.request_id,
                        adapter_instance_id="fixture-instance",
                        adapter_epoch=7,
                    ),
                    status=pb.SERVING,
                )

            def GetDescriptor(self, request, context):
                return pb.GetDescriptorResponse(
                    meta=pb.ResponseMeta(
                        code=pb.STATUS_OK,
                        request_id=request.request_id,
                        adapter_instance_id="fixture-instance",
                        adapter_epoch=7,
                    ),
                    descriptor=pb.PackageDescriptor(
                        game_id="gridwars",
                        adapter_version="1.0.0",
                        content_versions=["fixture"],
                        content_hashes=["a0b1"],
                        codec_ids=["gridwars.binary.v1"],
                        tick_rate=30,
                    ),
                )

            def GetSlotDescriptors(self, request, context):
                return pb.GetSlotDescriptorsResponse(
                    meta=pb.ResponseMeta(
                        code=pb.STATUS_OK,
                        request_id=request.request_id,
                        adapter_instance_id="fixture-instance",
                        adapter_epoch=7,
                    ),
                    slots=[
                        pb.OpaquePayload(
                            codec_id="gridwars.binary.v1",
                            value=b"\xff\x00opaque-not-json",
                        )
                    ],
                )

        server = grpc.server(futures.ThreadPoolExecutor(max_workers=1))
        pb_grpc.add_AdapterServiceServicer_to_server(Endpoint(), server)
        port = server.add_insecure_port("127.0.0.1:0")
        server.start()
        try:
            result = probe_endpoint(f"127.0.0.1:{port}")
        finally:
            server.stop(grace=None).wait()
        self.assertEqual(result["game_id"], "gridwars")
        self.assertEqual(result["slot_count"], 1)


if __name__ == "__main__":
    unittest.main()
