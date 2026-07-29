package gateway_test

import (
	"encoding/json"
	"testing"

	"github.com/chimerakang/hersir/rpc/gateway"
)

type alternateTranslator struct{}

func (alternateTranslator) ClientToV3(value []byte) (gateway.Envelope, error) {
	return gateway.NewEnvelope(gateway.TypeHello, gateway.Envelope{
		"protocol_versions": []any{3}, "game_id": "alternate",
		"game_version": "1", "content_hash": "hash", "codecs": []any{"alt.1"},
	}), nil
}

func (alternateTranslator) ServerFromV3(
	value gateway.Envelope, delivery string,
) ([]byte, error) {
	return json.Marshal(map[string]any{"kind": value["t"], "delivery": delivery})
}

func (alternateTranslator) Error(code, detail string) []byte {
	value, _ := json.Marshal(map[string]any{"kind": "error", "code": code})
	return value
}

func TestSecondProtocolIsAPluginWithoutSDKOrCoreChanges(t *testing.T) {
	value, err := gateway.New(gateway.Config{Translator: alternateTranslator{}})
	if err != nil {
		t.Fatal(err)
	}
	envelope, failure := value.ClientToV3([]byte("arbitrary-second-protocol"))
	if failure != nil || envelope["game_id"] != "alternate" {
		t.Fatalf("second protocol did not use the public translator seam: %s", failure)
	}
}
