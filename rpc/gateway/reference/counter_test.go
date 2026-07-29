package reference

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/chimerakang/hersir/rpc/gateway"
)

type goldenFile struct {
	Client []struct {
		Name   string           `json:"name"`
		Custom json.RawMessage  `json:"custom"`
		V3     gateway.Envelope `json:"v3"`
	} `json:"client"`
	Server []struct {
		Name   string           `json:"name"`
		V3     gateway.Envelope `json:"v3"`
		Custom map[string]any   `json:"custom"`
	} `json:"server"`
}

func TestGoldenBidirectionalTranslation(t *testing.T) {
	t.Parallel()
	_, file, _, _ := runtime.Caller(0)
	bytes, err := os.ReadFile(filepath.Join(filepath.Dir(file), "testdata",
		"counter_gateway_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixtures goldenFile
	if err := json.Unmarshal(bytes, &fixtures); err != nil {
		t.Fatal(err)
	}
	translator := CounterTranslator{}
	for _, fixture := range fixtures.Client {
		fixture := fixture
		t.Run(fixture.Name, func(t *testing.T) {
			actual, err := translator.ClientToV3(fixture.Custom)
			if err != nil {
				t.Fatal(err)
			}
			if err := gateway.ValidateClient(actual); err != nil {
				t.Fatal(err)
			}
			if !sameJSON(actual, fixture.V3) {
				t.Fatalf("translation mismatch\nwant %#v\ngot  %#v", fixture.V3, actual)
			}
		})
	}
	for _, fixture := range fixtures.Server {
		fixture := fixture
		t.Run(fixture.Name, func(t *testing.T) {
			actual, err := translator.ServerFromV3(
				fixture.V3, gateway.Reliability(fixture.V3))
			if err != nil {
				t.Fatal(err)
			}
			var decoded map[string]any
			if err := json.Unmarshal(actual, &decoded); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(decoded, fixture.Custom) {
				t.Fatalf("translation mismatch\nwant %#v\ngot  %#v",
					fixture.Custom, decoded)
			}
		})
	}
}

func TestGatewayRejectsMalformedOversizedAndRateLimitedFrames(t *testing.T) {
	now := time.Unix(10, 0)
	value, err := gateway.New(gateway.Config{
		Translator: CounterTranslator{}, MaxCustomBytes: 256,
		MessagesPerSecond: 2, Burst: 2, Now: func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	valid := []byte(`{"op":"open","versions":[3],"game":"counter-reference",` +
		`"release":"counter-rules.1","digest":"hash","formats":["counter.json.v1"]}`)
	if envelope, failure := value.ClientToV3(valid); envelope == nil || failure != nil {
		t.Fatalf("valid message rejected: %s", failure)
	}
	if envelope, failure := value.ClientToV3(
		[]byte(`{"op":"seat","queue":"quick","role":"participant","ticket":"a"}`)); envelope == nil || failure != nil {
		t.Fatalf("second message rejected: %s", failure)
	}
	_, failure := value.ClientToV3(valid)
	requireFault(t, failure, "slow_down")
	now = now.Add(time.Second)
	_, failure = value.ClientToV3([]byte(`{"op":"unknown"}`))
	requireFault(t, failure, "bad_message")
	_, failure = value.ClientToV3(make([]byte, 257))
	requireFault(t, failure, "too_large")
	telemetry := value.Telemetry()
	if telemetry.ClientMessages != 2 || telemetry.RateLimited != 1 ||
		telemetry.Malformed != 1 || telemetry.Oversized != 1 {
		t.Fatalf("unexpected gateway telemetry: %+v", telemetry)
	}
}

func TestDeliveryDowngradeIsExplicitAndObservable(t *testing.T) {
	t.Parallel()
	value, err := gateway.New(gateway.Config{Translator: CounterTranslator{}})
	if err != nil {
		t.Fatal(err)
	}
	message, err := value.ServerFromV3(gateway.NewEnvelope(gateway.TypeEvent,
		gateway.Envelope{
			"match_id": "m", "tick": 1, "reliability": gateway.Droppable,
			"codec_id": "counter.json.v1", "payload": map[string]any{"kind": "fx"},
		}))
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(message, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["delivery"] != "latest" || decoded["downgraded_from"] != gateway.Droppable {
		t.Fatalf("downgrade was not explicit: %s", message)
	}
	if value.Telemetry().DeliveryDowngrades != 1 {
		t.Fatal("delivery downgrade telemetry was not incremented")
	}
}

func requireFault(t *testing.T, value []byte, code string) {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(value, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["op"] != "fault" || decoded["code"] != code {
		t.Fatalf("expected fault %q, got %s", code, value)
	}
}

func sameJSON(left, right any) bool {
	leftBytes, _ := json.Marshal(left)
	rightBytes, _ := json.Marshal(right)
	return string(leftBytes) == string(rightBytes)
}
