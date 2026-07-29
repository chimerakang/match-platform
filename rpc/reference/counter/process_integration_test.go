package counter

import (
	"context"
	"net"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"testing"
	"time"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	"github.com/chimerakang/match-platform/rpc/recovery"
	rpcruntime "github.com/chimerakang/match-platform/rpc/runtime"
)

func TestProcessRuntimeFullLifecycleAndForcedRestartRecovery(t *testing.T) {
	rpcRoot := moduleRoot(t)
	binary := filepath.Join(t.TempDir(), "counter-adapter")
	build := exec.Command("go", "build", "-o", binary,
		"./reference/counter/cmd/counter-adapter")
	build.Dir = rpcRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build reference adapter: %v\n%s", err, output)
	}
	endpoint := freeEndpoint(t)
	process, err := rpcruntime.NewProcessRuntime(rpcruntime.Config{
		AdapterPackage:     GameID,
		Endpoint:           endpoint,
		Process:            rpcruntime.ProcessSpec{Command: binary},
		AllowInsecureTests: true,
		ReadyTimeout:       5 * time.Second,
		CallTimeout:        2 * time.Second,
		HealthInterval:     20 * time.Millisecond,
		LivenessInterval:   100 * time.Millisecond,
		LivenessFailures:   2,
		Restart: rpcruntime.RestartPolicy{
			MaxRestarts: 3,
			Backoff:     20 * time.Millisecond,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := process.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = process.Close() })

	_, instanceID, epoch := process.RuntimeIdentity()
	contextFor := func(requestID, expectedTick uint64) *adapterv1.RequestContext {
		return &adapterv1.RequestContext{
			Protocol: &adapterv1.ProtocolVersion{Major: 1}, MatchId: "process-276",
			AdapterInstanceId: instanceID, AdapterEpoch: epoch,
			RequestId: requestID, ExpectedTick: expectedTick,
			DeadlineUnixMs: uint64(time.Now().Add(2 * time.Second).UnixMilli()),
		}
	}
	created, err := process.CreateMatch(ctx, &adapterv1.CreateMatchRequest{
		Context: contextFor(1, 0),
		Config:  opaqueJSON(map[string]any{"match_id": "process-276", "limit": 12}),
		Seed:    276,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, created.GetMeta())

	store, err := recovery.NewFileStore(recovery.FileStoreConfig{
		Root: filepath.Join(t.TempDir(), "durable"),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	coordinator, err := recovery.NewCoordinator(recovery.CoordinatorConfig{
		MatchID: "process-276", CodecID: CodecID, Store: store, Runtime: process,
		InitialRequestID: 1, CheckpointEvery: 2, CallTimeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}

	if response, err := coordinator.ApplyCommand(ctx, opaqueJSON("slot_2"),
		opaqueJSON(command{Action: "increment", Amount: 3}), 0); err != nil {
		t.Fatal(err)
	} else {
		requireOK(t, response.GetMeta())
	}
	if response, err := coordinator.Advance(ctx, 1, 0); err != nil {
		t.Fatal(err)
	} else {
		requireOK(t, response.GetMeta())
	}
	// This command is durable but intentionally newer than the checkpoint.
	if response, err := coordinator.ApplyCommand(ctx, opaqueJSON("slot_1"),
		opaqueJSON(command{Action: "ready", Amount: 1}), 1); err != nil {
		t.Fatal(err)
	} else {
		requireOK(t, response.GetMeta())
	}
	before, err := coordinator.StateHash(ctx)
	if err != nil {
		t.Fatal(err)
	}
	oldEpoch := epoch
	if err := process.Kill(); err != nil {
		t.Fatal(err)
	}
	for epoch <= oldEpoch {
		select {
		case <-ctx.Done():
			t.Fatal("adapter process did not restart before the test deadline")
		case <-time.After(10 * time.Millisecond):
			_, instanceID, epoch = process.RuntimeIdentity()
		}
	}
	if err := process.AwaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	_, instanceID, epoch = process.RuntimeIdentity()
	if epoch <= oldEpoch {
		t.Fatalf("adapter epoch did not advance: %d -> %d", oldEpoch, epoch)
	}

	recoveredHash, err := coordinator.StateHash(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if recoveredHash.GetStateHash() != before.GetStateHash() {
		t.Fatal("forced process restart changed the durable state")
	}
	advanced, err := coordinator.Advance(ctx, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, advanced.GetMeta())

	readContext := func(requestID, expectedTick uint64) *adapterv1.RequestContext {
		return contextFor(requestID, expectedTick)
	}
	checkpoint, err := process.BuildCheckpoint(ctx, &adapterv1.BuildCheckpointRequest{
		Context: readContext(100, advanced.GetTick()), CodecId: CodecID,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, checkpoint.GetMeta())
	if !containsJSON(checkpoint.GetPayload().GetValue(), `"slot_1":true`) {
		t.Fatal("journal replay did not restore the pending ready command")
	}
	delta, err := process.BuildDelta(ctx, &adapterv1.BuildDeltaRequest{
		Context: readContext(101, advanced.GetTick()), FromAckTick: 1, CodecId: CodecID,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, delta.GetMeta())

	if response, err := coordinator.ApplyCommand(ctx, opaqueJSON("slot_3"),
		opaqueJSON(command{Action: "finish", Amount: 1}), advanced.GetTick()); err != nil {
		t.Fatal(err)
	} else {
		requireOK(t, response.GetMeta())
	}
	finalAdvance, err := coordinator.Advance(ctx, 1, advanced.GetTick())
	if err != nil {
		t.Fatal(err)
	}
	result, err := coordinator.TerminalResult(ctx)
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, result.GetMeta())
	if !result.GetPresent() {
		t.Fatal("terminal result missing after process recovery")
	}
	replay, err := coordinator.ExportReplay(ctx)
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, replay.GetMeta())
	if !replay.GetPresent() || !containsJSON(replay.GetPayload().GetValue(), `"game_id":"counter-reference"`) {
		t.Fatal("process adapter did not export the reference replay")
	}
	events, err := process.DrainEvents(ctx, &adapterv1.DrainEventsRequest{
		Context: readContext(102, finalAdvance.GetTick()), CodecId: CodecID, MaxEvents: 32,
	})
	if err != nil {
		t.Fatal(err)
	}
	requireOK(t, events.GetMeta())
	telemetry := coordinator.Telemetry()
	if telemetry.Recoveries != 1 || telemetry.ReplayedEntries == 0 {
		t.Fatalf("durable recovery was not observed: %+v", telemetry)
	}
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := goruntime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
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

func containsJSON(value []byte, fragment string) bool {
	for index := 0; index+len(fragment) <= len(value); index++ {
		if string(value[index:index+len(fragment)]) == fragment {
			return true
		}
	}
	return false
}
