package reference

import (
	"context"
	"encoding/json"
	"net"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"testing"
	"time"

	"github.com/chimerakang/match-platform/rpc/gateway"
	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	counter "github.com/chimerakang/match-platform/rpc/reference/counter"
	rpcruntime "github.com/chimerakang/match-platform/rpc/runtime"
)

func TestNonV3ClientCompletesMatchThroughGatewayAndProcessAdapter(t *testing.T) {
	rpcRoot := moduleRoot(t)
	binary := filepath.Join(t.TempDir(), "counter-adapter")
	build := exec.Command("go", "build", "-o", binary,
		"./reference/counter/cmd/counter-adapter")
	build.Dir = rpcRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build adapter: %v\n%s", err, output)
	}
	process, err := rpcruntime.NewProcessRuntime(rpcruntime.Config{
		AdapterPackage: counter.GameID, Endpoint: freeEndpoint(t),
		Process: rpcruntime.ProcessSpec{Command: binary}, AllowInsecureTests: true,
		ReadyTimeout: 5 * time.Second, CallTimeout: 2 * time.Second,
		HealthInterval: 20 * time.Millisecond, LivenessInterval: 100 * time.Millisecond,
		Restart: rpcruntime.RestartPolicy{MaxRestarts: 2, Backoff: 20 * time.Millisecond},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := process.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = process.Close() })

	bridge, err := gateway.New(gateway.Config{
		Translator: CounterTranslator{}, MaxCustomBytes: 4 << 10,
		MessagesPerSecond: 30, Burst: 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	deadline := func() uint64 {
		return uint64(time.Now().Add(2 * time.Second).UnixMilli())
	}
	descriptor, err := process.GetDescriptor(ctx, &adapterv1.GetDescriptorRequest{
		Protocol: &adapterv1.ProtocolVersion{Major: 1}, RequestId: 1,
		DeadlineUnixMs: deadline(),
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, descriptor.GetMeta())
	spec := descriptor.GetDescriptor_()

	open := mustCustom(map[string]any{
		"op": "open", "versions": []int{3}, "game": spec.GetGameId(),
		"release": spec.GetContentVersions()[0], "digest": spec.GetContentHashes()[0],
		"formats": spec.GetCodecIds(),
	})
	hello, failure := bridge.ClientToV3(open)
	if failure != nil || hello["t"] != gateway.TypeHello {
		t.Fatalf("custom open did not become V3 hello: %s", failure)
	}
	opened, err := bridge.ServerFromV3(gateway.NewEnvelope(gateway.TypeWelcome,
		gateway.Envelope{
			"selected_protocol": 3, "game_id": spec.GetGameId(),
			"adapter_version": spec.GetAdapterVersion(),
			"selected_codec":  spec.GetCodecIds()[0], "tick_rate": spec.GetTickRate(),
			"capabilities": map[string]any{"reconnect": true, "resync": true},
		}))
	if err != nil {
		t.Fatal(err)
	}
	requireCustomOp(t, opened, "opened")

	_, instanceID, epoch := process.RuntimeIdentity()
	requestContext := func(requestID, expectedTick uint64) *adapterv1.RequestContext {
		return &adapterv1.RequestContext{
			Protocol: &adapterv1.ProtocolVersion{Major: 1}, MatchId: "gateway-277",
			AdapterInstanceId: instanceID, AdapterEpoch: epoch, RequestId: requestID,
			ExpectedTick: expectedTick, DeadlineUnixMs: deadline(),
		}
	}
	created, err := process.CreateMatch(ctx, &adapterv1.CreateMatchRequest{
		Context: requestContext(1, 0),
		Config:  opaque(map[string]any{"match_id": "gateway-277", "limit": 10}),
		Seed:    277,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, created.GetMeta())

	slot := "slot_2"
	seat, failure := bridge.ClientToV3(mustCustom(map[string]any{
		"op": "seat", "queue": "quick", "role": "participant", "slot": slot,
		"ticket": "account:277", "resume": "resume:277",
	}))
	if failure != nil || seat["t"] != gateway.TypeJoin {
		t.Fatalf("custom seat did not become V3 join: %s", failure)
	}
	joined, err := process.ValidateJoin(ctx, &adapterv1.ValidateJoinRequest{
		Context: requestContext(2, 0), Role: seat["role"].(string),
		RequestedSlot: opaque(seat["requested_slot"]),
		AuthContext:   opaque(seat["auth_context"]),
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, joined.GetMeta())

	initial, err := process.BuildCheckpoint(ctx, &adapterv1.BuildCheckpointRequest{
		Context: requestContext(3, 0), CodecId: counter.CodecID,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, initial.GetMeta())
	snapshot, err := bridge.ServerFromV3(gateway.NewEnvelope(gateway.TypeCheckpoint,
		gateway.Envelope{
			"match_id": "gateway-277", "tick": initial.GetTick(),
			"codec_id":   counter.CodecID,
			"payload":    decodeOpaque(t, initial.GetPayload()),
			"state_hash": initial.GetStateHash(),
		}))
	if err != nil {
		t.Fatal(err)
	}
	requireCustomOp(t, snapshot, "snapshot")

	command, failure := bridge.ClientToV3(mustCustom(map[string]any{
		"op": "act", "match": "gateway-277", "no": 1, "base": 0,
		"format": counter.CodecID,
		"body":   map[string]any{"action": "increment", "amount": 3},
	}))
	if failure != nil {
		t.Fatalf("custom act rejected: %s", failure)
	}
	validation, err := process.ValidateCommand(ctx, &adapterv1.ValidateCommandRequest{
		Context: requestContext(4, 0), Slot: opaque(slot),
		Command: opaque(command["payload"]),
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, validation.GetMeta())
	applied, err := process.ApplyCommand(ctx, &adapterv1.ApplyCommandRequest{
		Context: requestContext(5, 0), Slot: opaque(slot),
		Command: opaque(command["payload"]),
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, applied.GetMeta())
	advanced, err := process.Advance(ctx, &adapterv1.AdvanceRequest{
		Context: requestContext(6, 0), Ticks: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, advanced.GetMeta())

	delta, err := process.BuildDelta(ctx, &adapterv1.BuildDeltaRequest{
		Context: requestContext(7, 1), FromAckTick: 0, CodecId: counter.CodecID,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, delta.GetMeta())
	sync, err := bridge.ServerFromV3(gateway.NewEnvelope(gateway.TypeState,
		gateway.Envelope{
			"match_id": "gateway-277", "tick": delta.GetTick(),
			"base_tick": delta.GetBaseTick(), "seq": 1, "codec_id": counter.CodecID,
			"payload": decodeOpaque(t, delta.GetPayload()),
		}))
	if err != nil {
		t.Fatal(err)
	}
	requireCustomOp(t, sync, "sync")
	events, err := process.DrainEvents(ctx, &adapterv1.DrainEventsRequest{
		Context: requestContext(8, 1), CodecId: counter.CodecID, MaxEvents: 32,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireRPCOK(t, events.GetMeta())
	if len(events.GetEvents()) != 1 {
		t.Fatalf("expected one reference event, got %d", len(events.GetEvents()))
	}
	notice, err := bridge.ServerFromV3(gateway.NewEnvelope(gateway.TypeEvent,
		gateway.Envelope{
			"match_id": "gateway-277", "tick": uint64(1),
			"reliability": gateway.Reliable, "codec_id": counter.CodecID,
			"payload": decodeOpaque(t, events.GetEvents()[0].GetPayload()),
		}))
	if err != nil {
		t.Fatal(err)
	}
	requireCustomOp(t, notice, "notice")

	finish, failure := bridge.ClientToV3(mustCustom(map[string]any{
		"op": "act", "match": "gateway-277", "no": 2, "base": 1,
		"format": counter.CodecID,
		"body":   map[string]any{"action": "finish"},
	}))
	if failure != nil {
		t.Fatalf("finish translation failed: %s", failure)
	}
	if response, err := process.ApplyCommand(ctx, &adapterv1.ApplyCommandRequest{
		Context: requestContext(9, 1), Slot: opaque(slot),
		Command: opaque(finish["payload"]),
	}); err != nil {
		t.Fatal(err)
	} else {
		requireRPCOK(t, response.GetMeta())
	}
	if response, err := process.Advance(ctx, &adapterv1.AdvanceRequest{
		Context: requestContext(10, 1), Ticks: 1,
	}); err != nil {
		t.Fatal(err)
	} else {
		requireRPCOK(t, response.GetMeta())
	}
	result, err := process.GetTerminalResult(ctx, &adapterv1.GetTerminalResultRequest{
		Context: requestContext(11, 2),
	})
	if err != nil {
		t.Fatal(err)
	}
	replay, err := process.ExportReplay(ctx, &adapterv1.ExportReplayRequest{
		Context: requestContext(12, 2),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.GetPresent() || !replay.GetPresent() {
		t.Fatal("non-V3 client did not complete and export the process match")
	}
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := goruntime.Caller(0)
	if !ok {
		t.Fatal("cannot locate module root")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

func freeEndpoint(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return endpoint
}

func opaque(value any) *adapterv1.OpaquePayload {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return &adapterv1.OpaquePayload{CodecId: counter.CodecID, Value: encoded}
}

func decodeOpaque(t *testing.T, value *adapterv1.OpaquePayload) any {
	t.Helper()
	var decoded any
	if err := json.Unmarshal(value.GetValue(), &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

func mustCustom(value any) []byte {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func requireCustomOp(t *testing.T, value []byte, operation string) {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(value, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["op"] != operation {
		t.Fatalf("expected custom operation %q, got %s", operation, value)
	}
}

func requireRPCOK(t *testing.T, meta *adapterv1.ResponseMeta) {
	t.Helper()
	if meta.GetCode() != adapterv1.StatusCode_STATUS_OK {
		t.Fatalf("adapter rejected request: %s (%s)", meta.GetCode(), meta.GetDetail())
	}
}
