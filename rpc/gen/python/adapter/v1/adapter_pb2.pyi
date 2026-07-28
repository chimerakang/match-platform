from google.protobuf.internal import containers as _containers
from google.protobuf.internal import enum_type_wrapper as _enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from collections.abc import Iterable as _Iterable, Mapping as _Mapping
from typing import ClassVar as _ClassVar, Optional as _Optional, Union as _Union

DESCRIPTOR: _descriptor.FileDescriptor

class StatusCode(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    STATUS_CODE_UNSPECIFIED: _ClassVar[StatusCode]
    STATUS_OK: _ClassVar[StatusCode]
    STATUS_INVALID_ARGUMENT: _ClassVar[StatusCode]
    STATUS_NOT_FOUND: _ClassVar[StatusCode]
    STATUS_ALREADY_EXISTS: _ClassVar[StatusCode]
    STATUS_ADAPTER_REJECTED: _ClassVar[StatusCode]
    STATUS_UNSUPPORTED_PROTOCOL: _ClassVar[StatusCode]
    STATUS_UNSUPPORTED_CAPABILITY: _ClassVar[StatusCode]
    STATUS_STALE_EPOCH: _ClassVar[StatusCode]
    STATUS_OUT_OF_ORDER: _ClassVar[StatusCode]
    STATUS_DEADLINE_EXCEEDED: _ClassVar[StatusCode]
    STATUS_CANCELLED: _ClassVar[StatusCode]
    STATUS_UNKNOWN_OUTCOME: _ClassVar[StatusCode]
    STATUS_PAYLOAD_TOO_LARGE: _ClassVar[StatusCode]
    STATUS_RESOURCE_EXHAUSTED: _ClassVar[StatusCode]
    STATUS_UNAVAILABLE: _ClassVar[StatusCode]
    STATUS_INTERNAL: _ClassVar[StatusCode]

class Reliability(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    RELIABILITY_UNSPECIFIED: _ClassVar[Reliability]
    RELIABILITY_RELIABLE: _ClassVar[Reliability]
    RELIABILITY_REPLACEABLE: _ClassVar[Reliability]
    RELIABILITY_DROPPABLE: _ClassVar[Reliability]

class ServingStatus(int, metaclass=_enum_type_wrapper.EnumTypeWrapper):
    __slots__ = ()
    SERVING_STATUS_UNSPECIFIED: _ClassVar[ServingStatus]
    SERVING: _ClassVar[ServingStatus]
    NOT_SERVING: _ClassVar[ServingStatus]
STATUS_CODE_UNSPECIFIED: StatusCode
STATUS_OK: StatusCode
STATUS_INVALID_ARGUMENT: StatusCode
STATUS_NOT_FOUND: StatusCode
STATUS_ALREADY_EXISTS: StatusCode
STATUS_ADAPTER_REJECTED: StatusCode
STATUS_UNSUPPORTED_PROTOCOL: StatusCode
STATUS_UNSUPPORTED_CAPABILITY: StatusCode
STATUS_STALE_EPOCH: StatusCode
STATUS_OUT_OF_ORDER: StatusCode
STATUS_DEADLINE_EXCEEDED: StatusCode
STATUS_CANCELLED: StatusCode
STATUS_UNKNOWN_OUTCOME: StatusCode
STATUS_PAYLOAD_TOO_LARGE: StatusCode
STATUS_RESOURCE_EXHAUSTED: StatusCode
STATUS_UNAVAILABLE: StatusCode
STATUS_INTERNAL: StatusCode
RELIABILITY_UNSPECIFIED: Reliability
RELIABILITY_RELIABLE: Reliability
RELIABILITY_REPLACEABLE: Reliability
RELIABILITY_DROPPABLE: Reliability
SERVING_STATUS_UNSPECIFIED: ServingStatus
SERVING: ServingStatus
NOT_SERVING: ServingStatus

class ProtocolVersion(_message.Message):
    __slots__ = ("major", "minor")
    MAJOR_FIELD_NUMBER: _ClassVar[int]
    MINOR_FIELD_NUMBER: _ClassVar[int]
    major: int
    minor: int
    def __init__(self, major: _Optional[int] = ..., minor: _Optional[int] = ...) -> None: ...

class Capability(_message.Message):
    __slots__ = ("name", "version")
    NAME_FIELD_NUMBER: _ClassVar[int]
    VERSION_FIELD_NUMBER: _ClassVar[int]
    name: str
    version: int
    def __init__(self, name: _Optional[str] = ..., version: _Optional[int] = ...) -> None: ...

class Limits(_message.Message):
    __slots__ = ("max_request_bytes", "max_response_bytes", "max_opaque_payload_bytes", "max_advance_ticks", "max_events_per_drain")
    MAX_REQUEST_BYTES_FIELD_NUMBER: _ClassVar[int]
    MAX_RESPONSE_BYTES_FIELD_NUMBER: _ClassVar[int]
    MAX_OPAQUE_PAYLOAD_BYTES_FIELD_NUMBER: _ClassVar[int]
    MAX_ADVANCE_TICKS_FIELD_NUMBER: _ClassVar[int]
    MAX_EVENTS_PER_DRAIN_FIELD_NUMBER: _ClassVar[int]
    max_request_bytes: int
    max_response_bytes: int
    max_opaque_payload_bytes: int
    max_advance_ticks: int
    max_events_per_drain: int
    def __init__(self, max_request_bytes: _Optional[int] = ..., max_response_bytes: _Optional[int] = ..., max_opaque_payload_bytes: _Optional[int] = ..., max_advance_ticks: _Optional[int] = ..., max_events_per_drain: _Optional[int] = ...) -> None: ...

class ResponseMeta(_message.Message):
    __slots__ = ("code", "detail", "retryable", "request_id", "observed_tick", "adapter_instance_id", "adapter_epoch")
    CODE_FIELD_NUMBER: _ClassVar[int]
    DETAIL_FIELD_NUMBER: _ClassVar[int]
    RETRYABLE_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    OBSERVED_TICK_FIELD_NUMBER: _ClassVar[int]
    ADAPTER_INSTANCE_ID_FIELD_NUMBER: _ClassVar[int]
    ADAPTER_EPOCH_FIELD_NUMBER: _ClassVar[int]
    code: StatusCode
    detail: str
    retryable: bool
    request_id: int
    observed_tick: int
    adapter_instance_id: str
    adapter_epoch: int
    def __init__(self, code: _Optional[_Union[StatusCode, str]] = ..., detail: _Optional[str] = ..., retryable: bool = ..., request_id: _Optional[int] = ..., observed_tick: _Optional[int] = ..., adapter_instance_id: _Optional[str] = ..., adapter_epoch: _Optional[int] = ...) -> None: ...

class RequestContext(_message.Message):
    __slots__ = ("protocol", "match_id", "adapter_instance_id", "adapter_epoch", "request_id", "deadline_unix_ms", "expected_tick")
    PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    MATCH_ID_FIELD_NUMBER: _ClassVar[int]
    ADAPTER_INSTANCE_ID_FIELD_NUMBER: _ClassVar[int]
    ADAPTER_EPOCH_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    DEADLINE_UNIX_MS_FIELD_NUMBER: _ClassVar[int]
    EXPECTED_TICK_FIELD_NUMBER: _ClassVar[int]
    protocol: ProtocolVersion
    match_id: str
    adapter_instance_id: str
    adapter_epoch: int
    request_id: int
    deadline_unix_ms: int
    expected_tick: int
    def __init__(self, protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., match_id: _Optional[str] = ..., adapter_instance_id: _Optional[str] = ..., adapter_epoch: _Optional[int] = ..., request_id: _Optional[int] = ..., deadline_unix_ms: _Optional[int] = ..., expected_tick: _Optional[int] = ...) -> None: ...

class OpaquePayload(_message.Message):
    __slots__ = ("codec_id", "value")
    CODEC_ID_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    codec_id: str
    value: bytes
    def __init__(self, codec_id: _Optional[str] = ..., value: _Optional[bytes] = ...) -> None: ...

class NegotiateRequest(_message.Message):
    __slots__ = ("client_name", "supported_protocols", "capabilities")
    CLIENT_NAME_FIELD_NUMBER: _ClassVar[int]
    SUPPORTED_PROTOCOLS_FIELD_NUMBER: _ClassVar[int]
    CAPABILITIES_FIELD_NUMBER: _ClassVar[int]
    client_name: str
    supported_protocols: _containers.RepeatedCompositeFieldContainer[ProtocolVersion]
    capabilities: _containers.RepeatedCompositeFieldContainer[Capability]
    def __init__(self, client_name: _Optional[str] = ..., supported_protocols: _Optional[_Iterable[_Union[ProtocolVersion, _Mapping]]] = ..., capabilities: _Optional[_Iterable[_Union[Capability, _Mapping]]] = ...) -> None: ...

class NegotiateResponse(_message.Message):
    __slots__ = ("meta", "selected_protocol", "capabilities", "limits")
    META_FIELD_NUMBER: _ClassVar[int]
    SELECTED_PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    CAPABILITIES_FIELD_NUMBER: _ClassVar[int]
    LIMITS_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    selected_protocol: ProtocolVersion
    capabilities: _containers.RepeatedCompositeFieldContainer[Capability]
    limits: Limits
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., selected_protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., capabilities: _Optional[_Iterable[_Union[Capability, _Mapping]]] = ..., limits: _Optional[_Union[Limits, _Mapping]] = ...) -> None: ...

class GetDescriptorRequest(_message.Message):
    __slots__ = ("protocol", "request_id", "deadline_unix_ms")
    PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    DEADLINE_UNIX_MS_FIELD_NUMBER: _ClassVar[int]
    protocol: ProtocolVersion
    request_id: int
    deadline_unix_ms: int
    def __init__(self, protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., request_id: _Optional[int] = ..., deadline_unix_ms: _Optional[int] = ...) -> None: ...

class PackageDescriptor(_message.Message):
    __slots__ = ("game_id", "adapter_version", "content_versions", "content_hashes", "codec_ids", "slot_policy", "tick_rate", "capabilities")
    GAME_ID_FIELD_NUMBER: _ClassVar[int]
    ADAPTER_VERSION_FIELD_NUMBER: _ClassVar[int]
    CONTENT_VERSIONS_FIELD_NUMBER: _ClassVar[int]
    CONTENT_HASHES_FIELD_NUMBER: _ClassVar[int]
    CODEC_IDS_FIELD_NUMBER: _ClassVar[int]
    SLOT_POLICY_FIELD_NUMBER: _ClassVar[int]
    TICK_RATE_FIELD_NUMBER: _ClassVar[int]
    CAPABILITIES_FIELD_NUMBER: _ClassVar[int]
    game_id: str
    adapter_version: str
    content_versions: _containers.RepeatedScalarFieldContainer[str]
    content_hashes: _containers.RepeatedScalarFieldContainer[str]
    codec_ids: _containers.RepeatedScalarFieldContainer[str]
    slot_policy: OpaquePayload
    tick_rate: int
    capabilities: _containers.RepeatedCompositeFieldContainer[Capability]
    def __init__(self, game_id: _Optional[str] = ..., adapter_version: _Optional[str] = ..., content_versions: _Optional[_Iterable[str]] = ..., content_hashes: _Optional[_Iterable[str]] = ..., codec_ids: _Optional[_Iterable[str]] = ..., slot_policy: _Optional[_Union[OpaquePayload, _Mapping]] = ..., tick_rate: _Optional[int] = ..., capabilities: _Optional[_Iterable[_Union[Capability, _Mapping]]] = ...) -> None: ...

class GetDescriptorResponse(_message.Message):
    __slots__ = ("meta", "descriptor")
    META_FIELD_NUMBER: _ClassVar[int]
    DESCRIPTOR_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    descriptor: PackageDescriptor
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., descriptor: _Optional[_Union[PackageDescriptor, _Mapping]] = ...) -> None: ...

class GetSlotDescriptorsRequest(_message.Message):
    __slots__ = ("protocol", "request_id", "deadline_unix_ms")
    PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    DEADLINE_UNIX_MS_FIELD_NUMBER: _ClassVar[int]
    protocol: ProtocolVersion
    request_id: int
    deadline_unix_ms: int
    def __init__(self, protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., request_id: _Optional[int] = ..., deadline_unix_ms: _Optional[int] = ...) -> None: ...

class GetSlotDescriptorsResponse(_message.Message):
    __slots__ = ("meta", "slots")
    META_FIELD_NUMBER: _ClassVar[int]
    SLOTS_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    slots: _containers.RepeatedCompositeFieldContainer[OpaquePayload]
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., slots: _Optional[_Iterable[_Union[OpaquePayload, _Mapping]]] = ...) -> None: ...

class ValidateMatchConfigRequest(_message.Message):
    __slots__ = ("protocol", "request_id", "deadline_unix_ms", "config")
    PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    DEADLINE_UNIX_MS_FIELD_NUMBER: _ClassVar[int]
    CONFIG_FIELD_NUMBER: _ClassVar[int]
    protocol: ProtocolVersion
    request_id: int
    deadline_unix_ms: int
    config: OpaquePayload
    def __init__(self, protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., request_id: _Optional[int] = ..., deadline_unix_ms: _Optional[int] = ..., config: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class CreateMatchRequest(_message.Message):
    __slots__ = ("context", "config", "seed")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    CONFIG_FIELD_NUMBER: _ClassVar[int]
    SEED_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    config: OpaquePayload
    seed: int
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., config: _Optional[_Union[OpaquePayload, _Mapping]] = ..., seed: _Optional[int] = ...) -> None: ...

class RecoverMatchRequest(_message.Message):
    __slots__ = ("context", "checkpoint")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    CHECKPOINT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    checkpoint: OpaquePayload
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., checkpoint: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class MatchResponse(_message.Message):
    __slots__ = ("meta", "match_id")
    META_FIELD_NUMBER: _ClassVar[int]
    MATCH_ID_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    match_id: str
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., match_id: _Optional[str] = ...) -> None: ...

class ValidateJoinRequest(_message.Message):
    __slots__ = ("context", "role", "requested_slot", "auth_context")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    ROLE_FIELD_NUMBER: _ClassVar[int]
    REQUESTED_SLOT_FIELD_NUMBER: _ClassVar[int]
    AUTH_CONTEXT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    role: str
    requested_slot: OpaquePayload
    auth_context: OpaquePayload
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., role: _Optional[str] = ..., requested_slot: _Optional[_Union[OpaquePayload, _Mapping]] = ..., auth_context: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class ValidateJoinResponse(_message.Message):
    __slots__ = ("meta", "assigned_slot")
    META_FIELD_NUMBER: _ClassVar[int]
    ASSIGNED_SLOT_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    assigned_slot: OpaquePayload
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., assigned_slot: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class ValidateCommandRequest(_message.Message):
    __slots__ = ("context", "slot", "command")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    SLOT_FIELD_NUMBER: _ClassVar[int]
    COMMAND_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    slot: OpaquePayload
    command: OpaquePayload
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., slot: _Optional[_Union[OpaquePayload, _Mapping]] = ..., command: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class ApplyCommandRequest(_message.Message):
    __slots__ = ("context", "slot", "command")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    SLOT_FIELD_NUMBER: _ClassVar[int]
    COMMAND_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    slot: OpaquePayload
    command: OpaquePayload
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., slot: _Optional[_Union[OpaquePayload, _Mapping]] = ..., command: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class StatusResponse(_message.Message):
    __slots__ = ("meta",)
    META_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ...) -> None: ...

class AdvanceRequest(_message.Message):
    __slots__ = ("context", "ticks")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    TICKS_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    ticks: int
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., ticks: _Optional[int] = ...) -> None: ...

class AdvanceResponse(_message.Message):
    __slots__ = ("meta", "tick")
    META_FIELD_NUMBER: _ClassVar[int]
    TICK_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    tick: int
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., tick: _Optional[int] = ...) -> None: ...

class GetTerminalResultRequest(_message.Message):
    __slots__ = ("context",)
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ...) -> None: ...

class GetStateHashRequest(_message.Message):
    __slots__ = ("context",)
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ...) -> None: ...

class ExportReplayRequest(_message.Message):
    __slots__ = ("context",)
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ...) -> None: ...

class OpaqueResponse(_message.Message):
    __slots__ = ("meta", "present", "payload")
    META_FIELD_NUMBER: _ClassVar[int]
    PRESENT_FIELD_NUMBER: _ClassVar[int]
    PAYLOAD_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    present: bool
    payload: OpaquePayload
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., present: bool = ..., payload: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class StateHashResponse(_message.Message):
    __slots__ = ("meta", "state_hash", "tick")
    META_FIELD_NUMBER: _ClassVar[int]
    STATE_HASH_FIELD_NUMBER: _ClassVar[int]
    TICK_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    state_hash: str
    tick: int
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., state_hash: _Optional[str] = ..., tick: _Optional[int] = ...) -> None: ...

class BuildCheckpointRequest(_message.Message):
    __slots__ = ("context", "codec_id")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    CODEC_ID_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    codec_id: str
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., codec_id: _Optional[str] = ...) -> None: ...

class CheckpointResponse(_message.Message):
    __slots__ = ("meta", "payload", "state_hash", "tick")
    META_FIELD_NUMBER: _ClassVar[int]
    PAYLOAD_FIELD_NUMBER: _ClassVar[int]
    STATE_HASH_FIELD_NUMBER: _ClassVar[int]
    TICK_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    payload: OpaquePayload
    state_hash: str
    tick: int
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., payload: _Optional[_Union[OpaquePayload, _Mapping]] = ..., state_hash: _Optional[str] = ..., tick: _Optional[int] = ...) -> None: ...

class BuildDeltaRequest(_message.Message):
    __slots__ = ("context", "from_ack_tick", "codec_id")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    FROM_ACK_TICK_FIELD_NUMBER: _ClassVar[int]
    CODEC_ID_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    from_ack_tick: int
    codec_id: str
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., from_ack_tick: _Optional[int] = ..., codec_id: _Optional[str] = ...) -> None: ...

class DeltaResponse(_message.Message):
    __slots__ = ("meta", "payload", "tick", "base_tick")
    META_FIELD_NUMBER: _ClassVar[int]
    PAYLOAD_FIELD_NUMBER: _ClassVar[int]
    TICK_FIELD_NUMBER: _ClassVar[int]
    BASE_TICK_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    payload: OpaquePayload
    tick: int
    base_tick: int
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., payload: _Optional[_Union[OpaquePayload, _Mapping]] = ..., tick: _Optional[int] = ..., base_tick: _Optional[int] = ...) -> None: ...

class AdapterEvent(_message.Message):
    __slots__ = ("reliability", "payload")
    RELIABILITY_FIELD_NUMBER: _ClassVar[int]
    PAYLOAD_FIELD_NUMBER: _ClassVar[int]
    reliability: Reliability
    payload: OpaquePayload
    def __init__(self, reliability: _Optional[_Union[Reliability, str]] = ..., payload: _Optional[_Union[OpaquePayload, _Mapping]] = ...) -> None: ...

class DrainEventsRequest(_message.Message):
    __slots__ = ("context", "codec_id", "max_events")
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    CODEC_ID_FIELD_NUMBER: _ClassVar[int]
    MAX_EVENTS_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    codec_id: str
    max_events: int
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ..., codec_id: _Optional[str] = ..., max_events: _Optional[int] = ...) -> None: ...

class DrainEventsResponse(_message.Message):
    __slots__ = ("meta", "events")
    META_FIELD_NUMBER: _ClassVar[int]
    EVENTS_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    events: _containers.RepeatedCompositeFieldContainer[AdapterEvent]
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., events: _Optional[_Iterable[_Union[AdapterEvent, _Mapping]]] = ...) -> None: ...

class Metric(_message.Message):
    __slots__ = ("name", "value")
    NAME_FIELD_NUMBER: _ClassVar[int]
    VALUE_FIELD_NUMBER: _ClassVar[int]
    name: str
    value: float
    def __init__(self, name: _Optional[str] = ..., value: _Optional[float] = ...) -> None: ...

class GetMetricsRequest(_message.Message):
    __slots__ = ("context",)
    CONTEXT_FIELD_NUMBER: _ClassVar[int]
    context: RequestContext
    def __init__(self, context: _Optional[_Union[RequestContext, _Mapping]] = ...) -> None: ...

class MetricsResponse(_message.Message):
    __slots__ = ("meta", "metrics")
    META_FIELD_NUMBER: _ClassVar[int]
    METRICS_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    metrics: _containers.RepeatedCompositeFieldContainer[Metric]
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., metrics: _Optional[_Iterable[_Union[Metric, _Mapping]]] = ...) -> None: ...

class HealthRequest(_message.Message):
    __slots__ = ("protocol", "request_id", "deadline_unix_ms")
    PROTOCOL_FIELD_NUMBER: _ClassVar[int]
    REQUEST_ID_FIELD_NUMBER: _ClassVar[int]
    DEADLINE_UNIX_MS_FIELD_NUMBER: _ClassVar[int]
    protocol: ProtocolVersion
    request_id: int
    deadline_unix_ms: int
    def __init__(self, protocol: _Optional[_Union[ProtocolVersion, _Mapping]] = ..., request_id: _Optional[int] = ..., deadline_unix_ms: _Optional[int] = ...) -> None: ...

class HealthResponse(_message.Message):
    __slots__ = ("meta", "status")
    META_FIELD_NUMBER: _ClassVar[int]
    STATUS_FIELD_NUMBER: _ClassVar[int]
    meta: ResponseMeta
    status: ServingStatus
    def __init__(self, meta: _Optional[_Union[ResponseMeta, _Mapping]] = ..., status: _Optional[_Union[ServingStatus, str]] = ...) -> None: ...
