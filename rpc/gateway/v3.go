package gateway

import (
	"encoding/json"
	"fmt"
)

const (
	EnvelopeVersion  = 3
	MaxEnvelopeBytes = 64 << 10

	TypeHello      = "hello"
	TypeWelcome    = "welcome"
	TypeJoin       = "join"
	TypeCommand    = "command"
	TypeState      = "state"
	TypeCheckpoint = "checkpoint"
	TypeEvent      = "event"
	TypeReject     = "reject"

	Reliable    = "reliable"
	Replaceable = "replaceable"
	Droppable   = "droppable"
)

const (
	RejectMalformed           = "malformed_envelope"
	RejectUnsupportedProtocol = "unsupported_protocol"
	RejectUnknownGame         = "unknown_game"
	RejectUnsupportedVersion  = "unsupported_game_version"
	RejectContentMismatch     = "content_hash_mismatch"
	RejectUnsupportedCodec    = "unsupported_codec"
	RejectUnknownMatch        = "unknown_match"
	RejectSlotUnavailable     = "slot_unavailable"
	RejectUnauthorized        = "unauthorized"
	RejectPayloadTooLarge     = "payload_too_large"
	RejectSequenceViolation   = "sequence_violation"
	RejectRateLimited         = "rate_limited"
	RejectAdapterRejected     = "adapter_rejected"
)

type Envelope map[string]any

var clientFields = map[string][]string{
	TypeHello: {
		"pv", "t", "protocol_versions", "game_id", "game_version",
		"content_hash", "codecs",
	},
	TypeJoin: {"pv", "t", "match_selector", "role", "auth_context"},
	TypeCommand: {
		"pv", "t", "match_id", "seq", "expected_tick", "codec_id", "payload",
	},
}

var serverFields = map[string][]string{
	TypeWelcome: {
		"pv", "t", "selected_protocol", "game_id", "adapter_version",
		"selected_codec", "tick_rate", "capabilities",
	},
	TypeState: {
		"pv", "t", "match_id", "tick", "base_tick", "seq", "codec_id", "payload",
	},
	TypeCheckpoint: {
		"pv", "t", "match_id", "tick", "codec_id", "payload", "state_hash",
	},
	TypeEvent: {
		"pv", "t", "match_id", "tick", "reliability", "codec_id", "payload",
	},
	TypeReject: {"pv", "t", "code"},
}

var rejectCodes = map[string]bool{
	RejectMalformed: true, RejectUnsupportedProtocol: true, RejectUnknownGame: true,
	RejectUnsupportedVersion: true, RejectContentMismatch: true,
	RejectUnsupportedCodec: true, RejectUnknownMatch: true,
	RejectSlotUnavailable: true, RejectUnauthorized: true,
	RejectPayloadTooLarge: true, RejectSequenceViolation: true,
	RejectRateLimited: true, RejectAdapterRejected: true,
}

func NewEnvelope(messageType string, fields Envelope) Envelope {
	result := cloneEnvelope(fields)
	result["pv"] = EnvelopeVersion
	result["t"] = messageType
	return result
}

func Reject(code, detail string) Envelope {
	result := NewEnvelope(TypeReject, Envelope{"code": code})
	if detail != "" {
		result["detail"] = detail
	}
	return result
}

func ValidateClient(value Envelope) error {
	return validate(value, clientFields)
}

func ValidateServer(value Envelope) error {
	return validate(value, serverFields)
}

func validate(value Envelope, allowed map[string][]string) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("%s: envelope is not JSON-safe", RejectMalformed)
	}
	if len(encoded) > MaxEnvelopeBytes {
		return fmt.Errorf("%s: envelope exceeds %d bytes", RejectPayloadTooLarge, MaxEnvelopeBytes)
	}
	if integer(value["pv"]) != EnvelopeVersion {
		return fmt.Errorf("%s: expected V3", RejectUnsupportedProtocol)
	}
	messageType, ok := value["t"].(string)
	if !ok {
		return fmt.Errorf("%s: message type is required", RejectMalformed)
	}
	fields, ok := allowed[messageType]
	if !ok {
		return fmt.Errorf("%s: message type %q is not allowed", RejectMalformed, messageType)
	}
	for _, field := range fields {
		if _, exists := value[field]; !exists {
			return fmt.Errorf("%s: field %q is required", RejectMalformed, field)
		}
	}
	if messageType == TypeReject {
		code, _ := value["code"].(string)
		if !rejectCodes[code] {
			return fmt.Errorf("%s: unknown rejection code", RejectMalformed)
		}
	}
	if messageType == TypeEvent {
		switch value["reliability"] {
		case Reliable, Replaceable, Droppable:
		default:
			return fmt.Errorf("%s: invalid event reliability", RejectMalformed)
		}
	}
	return nil
}

func Reliability(value Envelope) string {
	switch value["t"] {
	case TypeState:
		return Replaceable
	case TypeEvent:
		if reliability, ok := value["reliability"].(string); ok {
			return reliability
		}
	}
	return Reliable
}

func integer(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int64:
		return int(typed)
	case uint64:
		return int(typed)
	case float64:
		return int(typed)
	case json.Number:
		result, _ := typed.Int64()
		return int(result)
	default:
		return 0
	}
}

func cloneEnvelope(value Envelope) Envelope {
	result := make(Envelope, len(value)+2)
	for key, item := range value {
		result[key] = item
	}
	return result
}
