package recovery

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	adapterruntime "github.com/chimerakang/match-platform/rpc/runtime"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

type modelCheckpoint struct {
	Value int      `json:"value"`
	Tick  uint64   `json:"tick"`
	Log   []string `json:"log"`
}

type modelRuntime struct {
	adapterv1.AdapterServiceClient
	runtimeID  string
	instanceID string
	epoch      uint64
	value      int
	tick       uint64
	log        []string
}

var _ Runtime = (*modelRuntime)(nil)
var _ Runtime = (adapterruntime.AdapterRuntime)(nil)

func newModelRuntime(name string) *modelRuntime {
	return &modelRuntime{runtimeID: "runtime:" + name, instanceID: "instance:" + name + ":1", epoch: 1}
}

func (r *modelRuntime) RuntimeIdentity() (string, string, uint64) {
	return r.runtimeID, r.instanceID, r.epoch
}

func (r *modelRuntime) Restart() {
	r.epoch++
	r.instanceID = fmt.Sprintf("%s:epoch:%d", r.runtimeID, r.epoch)
	r.value = 0
	r.tick = 0
	r.log = nil
}

func (r *modelRuntime) meta(ctx *adapterv1.RequestContext) *adapterv1.ResponseMeta {
	return &adapterv1.ResponseMeta{
		Code: adapterv1.StatusCode_STATUS_OK, RequestId: ctx.GetRequestId(),
		ObservedTick: r.tick, AdapterInstanceId: r.instanceID, AdapterEpoch: r.epoch,
	}
}

func (r *modelRuntime) ApplyCommand(
	_ context.Context, request *adapterv1.ApplyCommandRequest, _ ...grpc.CallOption,
) (*adapterv1.StatusResponse, error) {
	delta, err := strconv.Atoi(string(request.GetCommand().GetValue()))
	if err != nil {
		return &adapterv1.StatusResponse{Meta: &adapterv1.ResponseMeta{
			Code: adapterv1.StatusCode_STATUS_INVALID_ARGUMENT,
		}}, nil
	}
	r.value += delta
	r.log = append(r.log, fmt.Sprintf("command:%d", delta))
	return &adapterv1.StatusResponse{Meta: r.meta(request.GetContext())}, nil
}

func (r *modelRuntime) Advance(
	_ context.Context, request *adapterv1.AdvanceRequest, _ ...grpc.CallOption,
) (*adapterv1.AdvanceResponse, error) {
	r.tick += uint64(request.GetTicks())
	r.value += int(request.GetTicks())
	r.log = append(r.log, fmt.Sprintf("advance:%d", request.GetTicks()))
	return &adapterv1.AdvanceResponse{
		Meta: r.meta(request.GetContext()), Tick: r.tick,
	}, nil
}

func (r *modelRuntime) BuildCheckpoint(
	_ context.Context, request *adapterv1.BuildCheckpointRequest, _ ...grpc.CallOption,
) (*adapterv1.CheckpointResponse, error) {
	payload, _ := json.Marshal(modelCheckpoint{Value: r.value, Tick: r.tick, Log: r.log})
	return &adapterv1.CheckpointResponse{
		Meta: r.meta(request.GetContext()),
		Payload: &adapterv1.OpaquePayload{
			CodecId: request.GetCodecId(), Value: payload,
		},
		StateHash: r.hash(), Tick: r.tick,
	}, nil
}

func (r *modelRuntime) RecoverMatch(
	_ context.Context, request *adapterv1.RecoverMatchRequest, _ ...grpc.CallOption,
) (*adapterv1.MatchResponse, error) {
	var checkpoint modelCheckpoint
	if err := json.Unmarshal(request.GetCheckpoint().GetValue(), &checkpoint); err != nil {
		return nil, err
	}
	r.value, r.tick = checkpoint.Value, checkpoint.Tick
	r.log = append([]string(nil), checkpoint.Log...)
	return &adapterv1.MatchResponse{
		Meta: r.meta(request.GetContext()), MatchId: request.GetContext().GetMatchId(),
	}, nil
}

func (r *modelRuntime) GetStateHash(
	_ context.Context, request *adapterv1.GetStateHashRequest, _ ...grpc.CallOption,
) (*adapterv1.StateHashResponse, error) {
	return &adapterv1.StateHashResponse{
		Meta: r.meta(request.GetContext()), StateHash: r.hash(), Tick: r.tick,
	}, nil
}

func (r *modelRuntime) ExportReplay(
	_ context.Context, request *adapterv1.ExportReplayRequest, _ ...grpc.CallOption,
) (*adapterv1.OpaqueResponse, error) {
	return &adapterv1.OpaqueResponse{
		Meta: r.meta(request.GetContext()), Present: true,
		Payload: &adapterv1.OpaquePayload{CodecId: "text", Value: []byte(strings.Join(r.log, "|"))},
	}, nil
}

func (r *modelRuntime) GetTerminalResult(
	_ context.Context, request *adapterv1.GetTerminalResultRequest, _ ...grpc.CallOption,
) (*adapterv1.OpaqueResponse, error) {
	return &adapterv1.OpaqueResponse{
		Meta: r.meta(request.GetContext()), Present: true,
		Payload: &adapterv1.OpaquePayload{
			CodecId: "text", Value: []byte(fmt.Sprintf("value=%d,tick=%d", r.value, r.tick)),
		},
	}, nil
}

func (r *modelRuntime) hash() string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%d:%d:%s", r.value, r.tick, strings.Join(r.log, "|"))))
	return hex.EncodeToString(sum[:])
}

func newTestCoordinator(t *testing.T, runtime *modelRuntime, store Store, checkpointEvery uint64) *Coordinator {
	t.Helper()
	coordinator, err := NewCoordinator(CoordinatorConfig{
		MatchID: "match-fixture", CodecID: "model-json", Store: store,
		Runtime: runtime, CheckpointEvery: checkpointEvery, CallTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	return coordinator
}

func fileStore(t *testing.T, config FileStoreConfig) *FileStore {
	t.Helper()
	if config.Root == "" {
		config.Root = t.TempDir()
	}
	store, err := NewFileStore(config)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func commandPayload(delta int) *adapterv1.OpaquePayload {
	return &adapterv1.OpaquePayload{CodecId: "int", Value: []byte(strconv.Itoa(delta))}
}

func TestCrashRecoveryMatchesEveryUninterruptedTickHash(t *testing.T) {
	baselineRuntime := newModelRuntime("baseline")
	recoveredRuntime := newModelRuntime("recovered")
	baseline := newTestCoordinator(t, baselineRuntime, fileStore(t, FileStoreConfig{}), 3)
	recoveredStore := fileStore(t, FileStoreConfig{RetainCheckpoints: 2, RetainDedupe: 8})
	recovered := newTestCoordinator(t, recoveredRuntime, recoveredStore, 3)

	type step struct {
		command *int
		ticks   uint32
	}
	delta3, delta5, deltaMinus2 := 3, 5, -2
	steps := []step{
		{command: &delta3}, {ticks: 2}, {command: &delta5},
		{ticks: 4}, {command: &deltaMinus2}, {ticks: 1},
	}
	for index, operation := range steps {
		if operation.command != nil {
			if _, err := baseline.ApplyCommand(context.Background(), nil, commandPayload(*operation.command), baselineRuntime.tick); err != nil {
				t.Fatal(err)
			}
			if _, err := recovered.ApplyCommand(context.Background(), nil, commandPayload(*operation.command), recoveredRuntime.tick); err != nil {
				t.Fatal(err)
			}
		} else {
			if _, err := baseline.Advance(context.Background(), operation.ticks, baselineRuntime.tick); err != nil {
				t.Fatal(err)
			}
			if _, err := recovered.Advance(context.Background(), operation.ticks, recoveredRuntime.tick); err != nil {
				t.Fatal(err)
			}
		}
		baselineHash, _ := baseline.StateHash(context.Background())
		recoveredRuntime.Restart()
		recoveredHash, err := recovered.StateHash(context.Background())
		if err != nil {
			t.Fatalf("step %d recovery failed: %v", index+1, err)
		}
		if recoveredHash.GetStateHash() != baselineHash.GetStateHash() {
			t.Fatalf("step %d hash=%s, want %s", index+1,
				recoveredHash.GetStateHash(), baselineHash.GetStateHash())
		}
	}
	baselineReplay, _ := baseline.ExportReplay(context.Background())
	recoveredReplay, _ := recovered.ExportReplay(context.Background())
	if !proto.Equal(baselineReplay.GetPayload(), recoveredReplay.GetPayload()) {
		t.Fatalf("replay differs: got %q want %q",
			recoveredReplay.GetPayload().GetValue(), baselineReplay.GetPayload().GetValue())
	}
	baselineResult, _ := baseline.TerminalResult(context.Background())
	recoveredResult, _ := recovered.TerminalResult(context.Background())
	if !proto.Equal(baselineResult.GetPayload(), recoveredResult.GetPayload()) {
		t.Fatalf("terminal result differs: got %q want %q",
			recoveredResult.GetPayload().GetValue(), baselineResult.GetPayload().GetValue())
	}
	telemetry := recovered.Telemetry()
	if telemetry.Recoveries != uint64(len(steps)) || telemetry.ReplayedEntries == 0 ||
		telemetry.CheckpointsSaved != 2 {
		t.Fatalf("unexpected recovery telemetry: %+v", telemetry)
	}
}

func TestDurableBoundariesRepairOrFailClosed(t *testing.T) {
	for _, point := range []FaultPoint{
		FaultAfterPrepareSync, FaultAfterCommitSync, FaultAfterCheckpointRename,
	} {
		t.Run(string(point), func(t *testing.T) {
			root := t.TempDir()
			armed := false
			store := fileStore(t, FileStoreConfig{
				Root: root,
				Fault: func(actual FaultPoint) error {
					if armed && actual == point {
						armed = false
						return errors.New("simulated power loss")
					}
					return nil
				},
			})
			mutation := Mutation{
				MatchID: "boundary", Epoch: 1, RequestID: 1,
				Operation: OperationApplyCommand, Request: []byte("request"),
			}
			armed = point == FaultAfterPrepareSync
			prepared, err := store.Prepare(context.Background(), mutation)
			if point == FaultAfterPrepareSync {
				if !IsCode(err, CodeStorage) {
					t.Fatalf("prepare fault = %v", err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			reopened := fileStore(t, FileStoreConfig{Root: root})
			state, err := reopened.Load(context.Background(), "boundary")
			if err != nil {
				t.Fatal(err)
			}
			if len(state.Entries) != 1 || state.Entries[0].Sequence != 1 {
				t.Fatalf("prepared entry was lost: %+v", state)
			}
			if point == FaultAfterPrepareSync {
				return
			}
			armed = point == FaultAfterCommitSync
			_, err = store.Commit(context.Background(), "boundary", prepared.Entry.Sequence,
				[]byte("response"), "hash-1")
			if point == FaultAfterCommitSync {
				if !IsCode(err, CodeStorage) {
					t.Fatalf("commit fault = %v", err)
				}
				state, err = reopened.Load(context.Background(), "boundary")
				if err != nil {
					t.Fatal(err)
				}
				if state.CommittedSequence != 1 || !state.Entries[0].Committed {
					t.Fatalf("synced commit was not repaired: %+v", state)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			armed = true
			err = store.SaveCheckpoint(context.Background(), Checkpoint{
				MatchID: "boundary", Sequence: 1, CodecID: "bytes",
				Payload: []byte("checkpoint"), StateHash: "hash-1", Tick: 1,
			})
			if !IsCode(err, CodeStorage) {
				t.Fatalf("checkpoint fault = %v", err)
			}
			state, err = reopened.Load(context.Background(), "boundary")
			if err != nil {
				t.Fatal(err)
			}
			if state.Checkpoint != nil || len(state.ReplayEntries()) != 1 {
				t.Fatalf("orphan checkpoint was made authoritative: %+v", state)
			}
		})
	}
}

func TestDuplicateAndStaleRequestsAreDeterministic(t *testing.T) {
	store := fileStore(t, FileStoreConfig{})
	mutation := Mutation{
		MatchID: "identity", Epoch: 2, RequestID: 7,
		Operation: OperationAdvance, Request: []byte("same"),
	}
	first, err := store.Prepare(context.Background(), mutation)
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err := store.Prepare(context.Background(), mutation)
	if err != nil || !duplicate.Duplicate || duplicate.Entry.Sequence != first.Entry.Sequence {
		t.Fatalf("identical duplicate = %+v, %v", duplicate, err)
	}
	different := mutation
	different.Request = []byte("different")
	if _, err := store.Prepare(context.Background(), different); !IsCode(err, CodeDuplicateMismatch) {
		t.Fatalf("different duplicate = %v", err)
	}
	stale := mutation
	stale.Epoch = 1
	stale.RequestID = 8
	if _, err := store.Prepare(context.Background(), stale); !IsCode(err, CodeStaleEpoch) {
		t.Fatalf("stale epoch = %v", err)
	}
	outOfOrder := mutation
	outOfOrder.RequestID = 6
	if _, err := store.Prepare(context.Background(), outOfOrder); !IsCode(err, CodeOutOfOrder) {
		t.Fatalf("out-of-order request = %v", err)
	}
}

func TestRecoveryRefusesToReplayIntoSameEpoch(t *testing.T) {
	store := fileStore(t, FileStoreConfig{})
	firstRuntime := newModelRuntime("same-epoch")
	first := newTestCoordinator(t, firstRuntime, store, 0)
	if _, err := first.ApplyCommand(
		context.Background(), nil, commandPayload(3), 0); err != nil {
		t.Fatal(err)
	}
	reconstructedCoordinator := newTestCoordinator(t, firstRuntime, store, 0)
	if _, err := reconstructedCoordinator.StateHash(context.Background()); !IsCode(err, CodeStaleEpoch) {
		t.Fatalf("same-epoch replay = %v, want stale_epoch", err)
	}
}

func TestCorruptAndIncompatibleStateFailsClosed(t *testing.T) {
	t.Run("corrupt journal", func(t *testing.T) {
		store := fileStore(t, FileStoreConfig{})
		_, err := store.Prepare(context.Background(), Mutation{
			MatchID: "corrupt", Epoch: 1, RequestID: 1,
			Operation: OperationAdvance, Request: []byte("wire"),
		})
		if err != nil {
			t.Fatal(err)
		}
		dir, _ := store.matchDir("corrupt")
		file, err := os.OpenFile(filepath.Join(dir, "journal.jsonl"), os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = file.WriteString(`{"truncated":`)
		_ = file.Close()
		if _, err := store.Load(context.Background(), "corrupt"); !IsCode(err, CodeCorrupt) {
			t.Fatalf("corrupt journal = %v", err)
		}
	})
	t.Run("corrupt checkpoint", func(t *testing.T) {
		store := fileStore(t, FileStoreConfig{})
		prepared, err := store.Prepare(context.Background(), Mutation{
			MatchID: "checkpoint-corrupt", Epoch: 1, RequestID: 1,
			Operation: OperationAdvance, Request: []byte("wire"),
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.Commit(context.Background(), "checkpoint-corrupt",
			prepared.Entry.Sequence, []byte("response"), "hash"); err != nil {
			t.Fatal(err)
		}
		if err := store.SaveCheckpoint(context.Background(), Checkpoint{
			MatchID: "checkpoint-corrupt", Sequence: 1, CodecID: "bytes",
			Payload: []byte("checkpoint"), StateHash: "hash", Tick: 1,
		}); err != nil {
			t.Fatal(err)
		}
		dir, _ := store.matchDir("checkpoint-corrupt")
		checkpoints, _ := filepath.Glob(filepath.Join(dir, "checkpoint-*.json"))
		if err := os.WriteFile(checkpoints[0], []byte("corrupt"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.Load(context.Background(), "checkpoint-corrupt"); !IsCode(err, CodeCorrupt) {
			t.Fatalf("corrupt checkpoint = %v", err)
		}
	})
	t.Run("watermark without commit record", func(t *testing.T) {
		store := fileStore(t, FileStoreConfig{})
		prepared, err := store.Prepare(context.Background(), Mutation{
			MatchID: "watermark", Epoch: 1, RequestID: 1,
			Operation: OperationAdvance, Request: []byte("wire"),
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.Commit(context.Background(), "watermark",
			prepared.Entry.Sequence, []byte("response"), "hash"); err != nil {
			t.Fatal(err)
		}
		dir, _ := store.matchDir("watermark")
		journalPath := filepath.Join(dir, "journal.jsonl")
		raw, _ := os.ReadFile(journalPath)
		lines := strings.Split(string(raw), "\n")
		if err := os.WriteFile(journalPath, []byte(lines[0]+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.Load(context.Background(), "watermark"); !IsCode(err, CodeCorrupt) {
			t.Fatalf("missing commit record = %v", err)
		}
	})
	t.Run("incompatible manifest", func(t *testing.T) {
		store := fileStore(t, FileStoreConfig{})
		_, err := store.Prepare(context.Background(), Mutation{
			MatchID: "version", Epoch: 1, RequestID: 1,
			Operation: OperationAdvance, Request: []byte("wire"),
		})
		if err != nil {
			t.Fatal(err)
		}
		dir, _ := store.matchDir("version")
		raw, _ := os.ReadFile(filepath.Join(dir, "manifest.json"))
		raw = []byte(strings.Replace(string(raw), `"version":1`, `"version":99`, 1))
		if err := os.WriteFile(filepath.Join(dir, "manifest.json"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.Load(context.Background(), "version"); !IsCode(err, CodeIncompatible) {
			t.Fatalf("incompatible manifest = %v", err)
		}
	})
	t.Run("incompatible checkpoint input", func(t *testing.T) {
		store := fileStore(t, FileStoreConfig{})
		if err := store.SaveCheckpoint(context.Background(), Checkpoint{
			Version: 99, MatchID: "future", Sequence: 1, CodecID: "bytes",
		}); !IsCode(err, CodeIncompatible) ||
			StatusCode(err) != adapterv1.StatusCode_STATUS_UNSUPPORTED_PROTOCOL {
			t.Fatalf("incompatible checkpoint = %v status=%s", err, StatusCode(err))
		}
	})
}

func TestRecoveryTimeStorageGrowthAndRetentionBudgets(t *testing.T) {
	store := fileStore(t, FileStoreConfig{RetainCheckpoints: 2, RetainDedupe: 16})
	runtime := newModelRuntime("budget")
	coordinator := newTestCoordinator(t, runtime, store, 10)
	started := time.Now()
	for index := 0; index < 100; index++ {
		if _, err := coordinator.Advance(context.Background(), 1, runtime.tick); err != nil {
			t.Fatal(err)
		}
	}
	writeDuration := time.Since(started)
	runtime.Restart()
	recoveryStarted := time.Now()
	if _, err := coordinator.StateHash(context.Background()); err != nil {
		t.Fatal(err)
	}
	recoveryDuration := time.Since(recoveryStarted)
	state, err := store.Load(context.Background(), "match-fixture")
	if err != nil {
		t.Fatal(err)
	}
	dir, _ := store.matchDir("match-fixture")
	checkpoints, _ := filepath.Glob(filepath.Join(dir, "checkpoint-*.json"))
	t.Logf("ADAPTER_RECOVERY_BENCH mutations=100 write=%s recovery=%s storage_bytes=%d",
		writeDuration, recoveryDuration, state.StorageBytes)
	if recoveryDuration > 500*time.Millisecond {
		t.Fatalf("recovery %s exceeds 500ms budget", recoveryDuration)
	}
	if state.StorageBytes > 512<<10 {
		t.Fatalf("storage %d exceeds 512KiB budget", state.StorageBytes)
	}
	if len(checkpoints) > 2 {
		t.Fatalf("retained %d checkpoints, want at most 2", len(checkpoints))
	}
}
