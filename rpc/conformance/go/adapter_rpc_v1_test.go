package conformance

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"reflect"
	"testing"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type goldenCorpus struct {
	Schema        int          `json:"schema"`
	ProtocolMajor uint32       `json:"protocol_major"`
	Cases         []goldenCase `json:"cases"`
}

type goldenCase struct {
	Name           string          `json:"name"`
	MessageType    string          `json:"message_type"`
	CanonicalHex   string          `json:"canonical_hex"`
	ExpectedStatus string          `json:"expected_status"`
	JSON           json.RawMessage `json:"json"`
}

func loadCorpus(t *testing.T) goldenCorpus {
	t.Helper()
	raw, err := os.ReadFile("../fixtures/adapter_rpc_v1_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var corpus goldenCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatal(err)
	}
	return corpus
}

func newMessage(name string) proto.Message {
	switch name {
	case "NegotiateRequest":
		return &adapterv1.NegotiateRequest{}
	case "CreateMatchRequest":
		return &adapterv1.CreateMatchRequest{}
	case "CheckpointResponse":
		return &adapterv1.CheckpointResponse{}
	default:
		return nil
	}
}

func negotiate(request *adapterv1.NegotiateRequest) *adapterv1.NegotiateResponse {
	var selected *adapterv1.ProtocolVersion
	for _, version := range request.GetSupportedProtocols() {
		if version.GetMajor() == 1 && (selected == nil || version.GetMinor() > selected.GetMinor()) {
			selected = version
		}
	}
	if selected == nil {
		return &adapterv1.NegotiateResponse{Meta: &adapterv1.ResponseMeta{
			Code:      adapterv1.StatusCode_STATUS_UNSUPPORTED_PROTOCOL,
			Detail:    "no compatible Adapter RPC major",
			Retryable: false,
		}}
	}
	return &adapterv1.NegotiateResponse{
		Meta:             &adapterv1.ResponseMeta{Code: adapterv1.StatusCode_STATUS_OK},
		SelectedProtocol: &adapterv1.ProtocolVersion{Major: 1, Minor: selected.GetMinor()},
	}
}

func TestGoldenFramesRoundTripDeterministically(t *testing.T) {
	for _, fixture := range loadCorpus(t).Cases {
		t.Run(fixture.Name, func(t *testing.T) {
			message := newMessage(fixture.MessageType)
			if message == nil {
				t.Fatalf("unknown fixture message type %q", fixture.MessageType)
			}
			if err := protojson.Unmarshal(fixture.JSON, message); err != nil {
				t.Fatal(err)
			}
			wire, err := (proto.MarshalOptions{Deterministic: true}).Marshal(message)
			if err != nil {
				t.Fatal(err)
			}
			if hex.EncodeToString(wire) != fixture.CanonicalHex {
				t.Fatalf("wire mismatch:\n got %x\nwant %s", wire, fixture.CanonicalHex)
			}
			decoded := newMessage(fixture.MessageType)
			if err := proto.Unmarshal(wire, decoded); err != nil {
				t.Fatal(err)
			}
			if !proto.Equal(message, decoded) {
				t.Fatalf("round trip changed %s", fixture.MessageType)
			}
		})
	}
}

func TestUnknownMajorIsRejectedBeforeDispatch(t *testing.T) {
	for _, fixture := range loadCorpus(t).Cases {
		if fixture.Name != "negotiate_unknown_major" {
			continue
		}
		wire, err := hex.DecodeString(fixture.CanonicalHex)
		if err != nil {
			t.Fatal(err)
		}
		request := &adapterv1.NegotiateRequest{}
		if err := proto.Unmarshal(wire, request); err != nil {
			t.Fatal(err)
		}
		response := negotiate(request)
		if response.GetMeta().GetCode().String() != fixture.ExpectedStatus {
			t.Fatalf("got %s, want %s", response.GetMeta().GetCode(), fixture.ExpectedStatus)
		}
		if response.GetMeta().GetRetryable() {
			t.Fatal("incompatible major must not be retryable")
		}
		return
	}
	t.Fatal("unknown-major fixture missing")
}

func TestGeneratedGoClientAndServerCoverFullSurface(t *testing.T) {
	expected := map[string]bool{
		"Negotiate": true, "GetDescriptor": true, "GetSlotDescriptors": true,
		"ValidateMatchConfig": true, "CreateMatch": true, "RecoverMatch": true, "ValidateJoin": true,
		"ValidateCommand": true, "ApplyCommand": true, "Advance": true,
		"GetTerminalResult": true, "GetStateHash": true, "ExportReplay": true,
		"BuildCheckpoint": true, "BuildDelta": true, "DrainEvents": true,
		"GetMetrics": true, "Health": true,
	}
	client := reflect.TypeOf((*adapterv1.AdapterServiceClient)(nil)).Elem()
	for index := 0; index < client.NumMethod(); index++ {
		delete(expected, client.Method(index).Name)
	}
	if len(expected) != 0 {
		t.Fatalf("generated client is missing methods: %v", expected)
	}
	if len(adapterv1.AdapterService_ServiceDesc.Methods) != 18 {
		t.Fatalf("generated server exposes %d methods, want 18", len(adapterv1.AdapterService_ServiceDesc.Methods))
	}
}
