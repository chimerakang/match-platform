package counter

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	"google.golang.org/protobuf/proto"
)

func TestAdapterFullLifecycleAndGodotParity(t *testing.T) {
	t.Parallel()
	adapter, err := New("test-instance", 1)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	deadline := uint64(time.Now().Add(time.Minute).UnixMilli())
	matchContext := func(requestID, expectedTick uint64) *adapterv1.RequestContext {
		return &adapterv1.RequestContext{
			Protocol: &adapterv1.ProtocolVersion{Major: 1}, MatchId: "match-276",
			AdapterInstanceId: "test-instance", AdapterEpoch: 1,
			RequestId: requestID, ExpectedTick: expectedTick, DeadlineUnixMs: deadline,
		}
	}

	negotiated, _ := adapter.Negotiate(ctx, &adapterv1.NegotiateRequest{
		SupportedProtocols: []*adapterv1.ProtocolVersion{{Major: 1}},
	})
	requireOK(t, negotiated.GetMeta())
	if negotiated.GetSelectedProtocol().GetMajor() != 1 {
		t.Fatal("protocol v1 was not negotiated")
	}
	descriptor, _ := adapter.GetDescriptor(ctx, &adapterv1.GetDescriptorRequest{
		Protocol: &adapterv1.ProtocolVersion{Major: 1}, RequestId: 1, DeadlineUnixMs: deadline,
	})
	requireOK(t, descriptor.GetMeta())
	if descriptor.GetDescriptor_().GetGameId() != GameID ||
		descriptor.GetDescriptor_().GetContentHashes()[0] != contentHash() {
		t.Fatal("descriptor differs from the in-process reference package")
	}
	slots, _ := adapter.GetSlotDescriptors(ctx, &adapterv1.GetSlotDescriptorsRequest{
		Protocol: &adapterv1.ProtocolVersion{Major: 1}, RequestId: 2, DeadlineUnixMs: deadline,
	})
	requireOK(t, slots.GetMeta())
	if len(slots.GetSlots()) != 4 {
		t.Fatalf("got %d slot descriptors", len(slots.GetSlots()))
	}
	config := opaqueJSON(map[string]any{"match_id": "match-276", "limit": 8})
	checked, _ := adapter.ValidateMatchConfig(ctx, &adapterv1.ValidateMatchConfigRequest{
		Protocol: &adapterv1.ProtocolVersion{Major: 1}, RequestId: 3,
		DeadlineUnixMs: deadline, Config: config,
	})
	requireOK(t, checked.GetMeta())
	created, _ := adapter.CreateMatch(ctx, &adapterv1.CreateMatchRequest{
		Context: matchContext(1, 0), Config: config, Seed: 276,
	})
	requireOK(t, created.GetMeta())

	joined, _ := adapter.ValidateJoin(ctx, &adapterv1.ValidateJoinRequest{
		Context: matchContext(2, 0), Role: "participant",
		RequestedSlot: opaqueJSON("slot_2"), AuthContext: opaqueJSON(map[string]any{}),
	})
	requireOK(t, joined.GetMeta())
	if string(joined.GetAssignedSlot().GetValue()) != `"slot_2"` {
		t.Fatalf("unexpected assigned slot %s", joined.GetAssignedSlot().GetValue())
	}

	ready := opaqueJSON(command{Action: "ready", Amount: 1})
	validated, _ := adapter.ValidateCommand(ctx, &adapterv1.ValidateCommandRequest{
		Context: matchContext(3, 0), Slot: opaqueJSON("slot_1"), Command: ready,
	})
	requireOK(t, validated.GetMeta())
	appliedRequest := &adapterv1.ApplyCommandRequest{
		Context: matchContext(4, 0), Slot: opaqueJSON("slot_1"), Command: ready,
	}
	applied, _ := adapter.ApplyCommand(ctx, appliedRequest)
	requireOK(t, applied.GetMeta())
	duplicate, _ := adapter.ApplyCommand(ctx, proto.Clone(appliedRequest).(*adapterv1.ApplyCommandRequest))
	requireOK(t, duplicate.GetMeta())
	advanced, _ := adapter.Advance(ctx, &adapterv1.AdvanceRequest{
		Context: matchContext(5, 0), Ticks: 1,
	})
	requireOK(t, advanced.GetMeta())

	increment := opaqueJSON(command{Action: "increment", Amount: 3})
	applied, _ = adapter.ApplyCommand(ctx, &adapterv1.ApplyCommandRequest{
		Context: matchContext(6, 1), Slot: opaqueJSON("slot_2"), Command: increment,
	})
	requireOK(t, applied.GetMeta())
	advanced, _ = adapter.Advance(ctx, &adapterv1.AdvanceRequest{
		Context: matchContext(7, 1), Ticks: 1,
	})
	requireOK(t, advanced.GetMeta())

	deltaResponse, _ := adapter.BuildDelta(ctx, &adapterv1.BuildDeltaRequest{
		Context: matchContext(8, 2), FromAckTick: 0, CodecId: CodecID,
	})
	requireOK(t, deltaResponse.GetMeta())
	drainRequest := &adapterv1.DrainEventsRequest{
		Context: matchContext(9, 2), CodecId: CodecID, MaxEvents: 20,
	}
	events, _ := adapter.DrainEvents(ctx, drainRequest)
	requireOK(t, events.GetMeta())
	if len(events.GetEvents()) != 2 {
		t.Fatalf("got %d events before completion", len(events.GetEvents()))
	}
	retriedEvents, _ := adapter.DrainEvents(ctx,
		proto.Clone(drainRequest).(*adapterv1.DrainEventsRequest))
	if len(retriedEvents.GetEvents()) != 2 {
		t.Fatal("exact drain retry did not return its idempotent response")
	}

	finished, _ := adapter.ApplyCommand(ctx, &adapterv1.ApplyCommandRequest{
		Context: matchContext(10, 2), Slot: opaqueJSON("slot_3"),
		Command: opaqueJSON(command{Action: "finish", Amount: 1}),
	})
	requireOK(t, finished.GetMeta())
	advanced, _ = adapter.Advance(ctx, &adapterv1.AdvanceRequest{
		Context: matchContext(11, 2), Ticks: 1,
	})
	requireOK(t, advanced.GetMeta())

	expectedState := `{"seed":276,"step":3,"limit":8,"closed":true,` +
		`"values":{"slot_1":0,"slot_2":3,"slot_3":0},` +
		`"prepared":{"slot_1":true,"slot_2":false,"slot_3":false},` +
		`"completion":{"completed_by":"slot_3","totals":{"slot_1":0,"slot_2":3,"slot_3":0},"step":2}}`
	sum := sha256.Sum256([]byte(expectedState))
	expectedHash := hex.EncodeToString(sum[:])
	hash, _ := adapter.GetStateHash(ctx, &adapterv1.GetStateHashRequest{
		Context: matchContext(12, 3),
	})
	requireOK(t, hash.GetMeta())
	if hash.GetStateHash() != expectedHash {
		t.Fatalf("state encoding differs from Godot JSON.stringify\nwant %s\ngot  %s",
			expectedHash, hash.GetStateHash())
	}
	result, _ := adapter.GetTerminalResult(ctx, &adapterv1.GetTerminalResultRequest{
		Context: matchContext(13, 3),
	})
	requireOK(t, result.GetMeta())
	if !result.GetPresent() {
		t.Fatal("terminal result is absent")
	}
	replayResponse, _ := adapter.ExportReplay(ctx, &adapterv1.ExportReplayRequest{
		Context: matchContext(14, 3),
	})
	requireOK(t, replayResponse.GetMeta())
	var replayValue replay
	if err := json.Unmarshal(replayResponse.GetPayload().GetValue(), &replayValue); err != nil {
		t.Fatal(err)
	}
	if replayValue.StateHash != expectedHash || len(replayValue.Log) != 3 {
		t.Fatal("replay is not equivalent to the in-process reference")
	}
	checkpointResponse, _ := adapter.BuildCheckpoint(ctx, &adapterv1.BuildCheckpointRequest{
		Context: matchContext(15, 3), CodecId: CodecID,
	})
	requireOK(t, checkpointResponse.GetMeta())

	recovered, err := New("recovered-instance", 2)
	if err != nil {
		t.Fatal(err)
	}
	recoverContext := &adapterv1.RequestContext{
		Protocol: &adapterv1.ProtocolVersion{Major: 1}, MatchId: "match-276",
		AdapterInstanceId: "recovered-instance", AdapterEpoch: 2,
		RequestId: 1, ExpectedTick: 3, DeadlineUnixMs: deadline,
	}
	recoveredResponse, _ := recovered.RecoverMatch(ctx, &adapterv1.RecoverMatchRequest{
		Context: recoverContext, Checkpoint: checkpointResponse.GetPayload(),
	})
	requireOK(t, recoveredResponse.GetMeta())
	recoverContext.RequestId = 2
	recoveredHash, _ := recovered.GetStateHash(ctx, &adapterv1.GetStateHashRequest{
		Context: recoverContext,
	})
	if recoveredHash.GetStateHash() != expectedHash {
		t.Fatal("checkpoint recovery changed the authoritative state")
	}
}

func requireOK(t *testing.T, meta *adapterv1.ResponseMeta) {
	t.Helper()
	if meta.GetCode() != adapterv1.StatusCode_STATUS_OK {
		t.Fatalf("RPC rejected: %s (%s)", meta.GetCode(), meta.GetDetail())
	}
}

func opaqueJSON(value any) *adapterv1.OpaquePayload {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return &adapterv1.OpaquePayload{CodecId: CodecID, Value: encoded}
}
