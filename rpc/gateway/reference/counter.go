package reference

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"

	"github.com/chimerakang/match-platform/rpc/gateway"
)

// CounterTranslator demonstrates a deliberately non-V3 game protocol. Its
// vocabulary is confined to this game-owned package.
type CounterTranslator struct{}

type clientMessage struct {
	Op       string          `json:"op"`
	Versions []int           `json:"versions,omitempty"`
	Game     string          `json:"game,omitempty"`
	Release  string          `json:"release,omitempty"`
	Digest   string          `json:"digest,omitempty"`
	Formats  []string        `json:"formats,omitempty"`
	Queue    string          `json:"queue,omitempty"`
	Role     string          `json:"role,omitempty"`
	Slot     *string         `json:"slot,omitempty"`
	Ticket   string          `json:"ticket,omitempty"`
	Resume   string          `json:"resume,omitempty"`
	Match    string          `json:"match,omitempty"`
	No       int             `json:"no,omitempty"`
	Base     uint64          `json:"base,omitempty"`
	Format   string          `json:"format,omitempty"`
	Body     json.RawMessage `json:"body,omitempty"`
}

func (CounterTranslator) ClientToV3(value []byte) (gateway.Envelope, error) {
	var message clientMessage
	decoder := json.NewDecoder(bytes.NewReader(value))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&message); err != nil {
		return nil, fmt.Errorf("decode counter message: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("multiple counter messages in one frame")
	}
	switch message.Op {
	case "open":
		if message.Game == "" || message.Release == "" || message.Digest == "" ||
			len(message.Versions) == 0 || len(message.Formats) == 0 {
			return nil, fmt.Errorf("open identity and negotiation fields are required")
		}
		return gateway.NewEnvelope(gateway.TypeHello, gateway.Envelope{
			"protocol_versions": intsToAny(message.Versions),
			"game_id":           message.Game, "game_version": message.Release,
			"content_hash": message.Digest, "codecs": stringsToAny(message.Formats),
		}), nil
	case "seat":
		if message.Queue == "" || message.Role == "" || message.Ticket == "" {
			return nil, fmt.Errorf("seat queue, role and ticket are required")
		}
		auth := gateway.Envelope{"identity": message.Ticket}
		if message.Resume != "" {
			auth["reconnect_token"] = message.Resume
		}
		fields := gateway.Envelope{
			"match_selector": gateway.Envelope{"kind": message.Queue},
			"role":           message.Role, "auth_context": auth,
		}
		if message.Slot != nil && *message.Slot != "" {
			fields["requested_slot"] = *message.Slot
		}
		return gateway.NewEnvelope(gateway.TypeJoin, fields), nil
	case "act":
		if message.Match == "" || message.No <= 0 || message.Format == "" ||
			len(message.Body) == 0 {
			return nil, fmt.Errorf("act match, no, format and body are required")
		}
		var payload any
		if err := json.Unmarshal(message.Body, &payload); err != nil {
			return nil, fmt.Errorf("act body is invalid: %w", err)
		}
		return gateway.NewEnvelope(gateway.TypeCommand, gateway.Envelope{
			"match_id": message.Match, "seq": message.No,
			"expected_tick": message.Base, "codec_id": message.Format,
			"payload": payload,
		}), nil
	default:
		return nil, fmt.Errorf("unknown counter operation %q", message.Op)
	}
}

func (CounterTranslator) ServerFromV3(value gateway.Envelope, delivery string) ([]byte, error) {
	var result map[string]any
	switch value["t"] {
	case gateway.TypeWelcome:
		result = map[string]any{
			"op": "opened", "version": value["selected_protocol"],
			"game": value["game_id"], "adapter": value["adapter_version"],
			"format": value["selected_codec"], "hz": value["tick_rate"],
			"features": value["capabilities"],
		}
	case gateway.TypeCheckpoint:
		result = map[string]any{
			"op": "snapshot", "match": value["match_id"], "step": value["tick"],
			"format": value["codec_id"], "body": value["payload"],
			"hash": value["state_hash"], "delivery": "reliable",
		}
	case gateway.TypeState:
		result = map[string]any{
			"op": "sync", "match": value["match_id"], "step": value["tick"],
			"from": value["base_tick"], "no": value["seq"],
			"format": value["codec_id"], "body": value["payload"],
			"delivery": "latest",
		}
	case gateway.TypeEvent:
		customDelivery := "reliable"
		if delivery != gateway.Reliable {
			customDelivery = "latest"
		}
		result = map[string]any{
			"op": "notice", "match": value["match_id"], "step": value["tick"],
			"format": value["codec_id"], "body": value["payload"],
			"delivery": customDelivery,
		}
		if delivery == gateway.Droppable {
			// The sample transport has no fire-and-forget class. It deliberately
			// upgrades droppable events to replaceable/latest.
			result["downgraded_from"] = gateway.Droppable
		}
	case gateway.TypeReject:
		code, _ := value["code"].(string)
		result = map[string]any{
			"op": "fault", "code": customErrorCode(code), "v3_code": code,
		}
		if detail, ok := value["detail"].(string); ok && detail != "" {
			result["detail"] = detail
		}
	default:
		return nil, fmt.Errorf("unsupported V3 server message %q", value["t"])
	}
	return json.Marshal(result)
}

func (translator CounterTranslator) Error(code, detail string) []byte {
	result, _ := translator.ServerFromV3(gateway.Reject(code, detail), gateway.Reliable)
	return result
}

func customErrorCode(code string) string {
	switch code {
	case gateway.RejectMalformed:
		return "bad_message"
	case gateway.RejectUnsupportedProtocol, gateway.RejectUnsupportedVersion:
		return "upgrade_required"
	case gateway.RejectUnknownGame, gateway.RejectUnknownMatch:
		return "not_found"
	case gateway.RejectContentMismatch, gateway.RejectUnsupportedCodec:
		return "incompatible"
	case gateway.RejectUnauthorized:
		return "denied"
	case gateway.RejectSlotUnavailable:
		return "seat_busy"
	case gateway.RejectPayloadTooLarge:
		return "too_large"
	case gateway.RejectSequenceViolation:
		return "bad_sequence"
	case gateway.RejectRateLimited:
		return "slow_down"
	default:
		return "game_rejected"
	}
}

func intsToAny(values []int) []any {
	result := make([]any, len(values))
	for index, value := range values {
		result[index] = value
	}
	return result
}

func stringsToAny(values []string) []any {
	result := make([]any, len(values))
	for index, value := range values {
		result[index] = value
	}
	return result
}
