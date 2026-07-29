package recovery

import (
	"context"
	"fmt"
	"sync"
	"time"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	"google.golang.org/protobuf/proto"
)

type Runtime interface {
	adapterv1.AdapterServiceClient
	RuntimeIdentity() (runtimeID, adapterInstanceID string, adapterEpoch uint64)
}

type CoordinatorConfig struct {
	MatchID string
	CodecID string
	Store   Store
	Runtime Runtime
	// InitialRequestID reserves request ids already consumed while creating the
	// match before the durable coordinator takes ownership of mutations.
	InitialRequestID uint64
	CheckpointEvery  uint64
	CallTimeout      time.Duration
}

type RecoveryTelemetry struct {
	MatchID              string
	Recoveries           uint64
	RecoveryFailures     uint64
	ReplayedEntries      uint64
	CheckpointsSaved     uint64
	CheckpointFailures   uint64
	LastRecoveryDuration time.Duration
	LastStorageBytes     int64
}

// Coordinator serializes authoritative mutations. A journal prepare is fsynced
// before dispatch and the committed watermark is advanced only after the adapter
// response and resulting state hash are durable.
type Coordinator struct {
	cfg CoordinatorConfig

	mu            sync.Mutex
	activeEpoch   uint64
	nextRequestID uint64
	telemetry     RecoveryTelemetry
}

func NewCoordinator(cfg CoordinatorConfig) (*Coordinator, error) {
	if cfg.MatchID == "" || cfg.CodecID == "" || cfg.Store == nil || cfg.Runtime == nil {
		return nil, fmt.Errorf("match, codec, store and runtime are required")
	}
	if cfg.CallTimeout <= 0 {
		cfg.CallTimeout = 5 * time.Second
	}
	return &Coordinator{
		cfg:           cfg,
		nextRequestID: cfg.InitialRequestID,
		telemetry:     RecoveryTelemetry{MatchID: cfg.MatchID},
	}, nil
}

func (c *Coordinator) Telemetry() RecoveryTelemetry {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.telemetry
}

func (c *Coordinator) ApplyCommand(
	ctx context.Context,
	slot, command *adapterv1.OpaquePayload,
	expectedTick uint64,
) (*adapterv1.StatusResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return nil, err
	}
	request := &adapterv1.ApplyCommandRequest{
		Context: c.nextContextLocked(expectedTick),
		Slot:    clonePayload(slot),
		Command: clonePayload(command),
	}
	response := new(adapterv1.StatusResponse)
	entry, err := c.invokeMutationLocked(ctx, OperationApplyCommand, request, response,
		func(callCtx context.Context) error {
			value, callErr := c.cfg.Runtime.ApplyCommand(callCtx, request)
			if callErr == nil {
				proto.Merge(response, value)
			}
			return callErr
		})
	if err != nil {
		return nil, err
	}
	c.maybeCheckpointLocked(ctx, entry.Sequence)
	return response, nil
}

func (c *Coordinator) Advance(
	ctx context.Context, ticks uint32, expectedTick uint64,
) (*adapterv1.AdvanceResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return nil, err
	}
	request := &adapterv1.AdvanceRequest{
		Context: c.nextContextLocked(expectedTick),
		Ticks:   ticks,
	}
	response := new(adapterv1.AdvanceResponse)
	entry, err := c.invokeMutationLocked(ctx, OperationAdvance, request, response,
		func(callCtx context.Context) error {
			value, callErr := c.cfg.Runtime.Advance(callCtx, request)
			if callErr == nil {
				proto.Merge(response, value)
			}
			return callErr
		})
	if err != nil {
		return nil, err
	}
	c.maybeCheckpointLocked(ctx, entry.Sequence)
	return response, nil
}

func (c *Coordinator) StateHash(ctx context.Context) (*adapterv1.StateHashResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return nil, err
	}
	return c.stateHashLocked(ctx)
}

func (c *Coordinator) TerminalResult(ctx context.Context) (*adapterv1.OpaqueResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return nil, err
	}
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	defer cancel()
	return c.cfg.Runtime.GetTerminalResult(callCtx, &adapterv1.GetTerminalResultRequest{
		Context: c.nextContextLocked(0),
	})
}

func (c *Coordinator) ExportReplay(ctx context.Context) (*adapterv1.OpaqueResponse, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return nil, err
	}
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	defer cancel()
	return c.cfg.Runtime.ExportReplay(callCtx, &adapterv1.ExportReplayRequest{
		Context: c.nextContextLocked(0),
	})
}

func (c *Coordinator) Checkpoint(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.ensureRecoveredLocked(ctx); err != nil {
		return err
	}
	state, err := c.cfg.Store.Load(ctx, c.cfg.MatchID)
	if err != nil {
		return err
	}
	if state.CommittedSequence == 0 {
		return nil
	}
	return c.checkpointLocked(ctx, state.CommittedSequence)
}

func (c *Coordinator) Recover(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.activeEpoch = 0
	return c.ensureRecoveredLocked(ctx)
}

func (c *Coordinator) invokeMutationLocked(
	ctx context.Context,
	operation Operation,
	request proto.Message,
	response proto.Message,
	invoke func(context.Context) error,
) (Entry, error) {
	requestBytes, err := (proto.MarshalOptions{Deterministic: true}).Marshal(request)
	if err != nil {
		return Entry{}, err
	}
	requestContext := contextFromRequest(request)
	prepared, err := c.cfg.Store.Prepare(ctx, Mutation{
		MatchID: c.cfg.MatchID, Epoch: requestContext.GetAdapterEpoch(),
		RequestID: requestContext.GetRequestId(), Operation: operation,
		Request: requestBytes,
	})
	if err != nil {
		return Entry{}, err
	}
	if prepared.Duplicate {
		if !prepared.Entry.Committed {
			return Entry{}, fail(CodeUnknownOutcome,
				"prepared request has no durable adapter result; recover before retry", nil)
		}
		if err := proto.Unmarshal(prepared.Entry.Response, response); err != nil {
			return Entry{}, fail(CodeCorrupt, "durable response is malformed", err)
		}
		return prepared.Entry, nil
	}
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	defer cancel()
	if err := invoke(callCtx); err != nil {
		return Entry{}, fail(CodeAdapter, "mutation RPC did not complete", err)
	}
	if metaFromResponse(response) == nil {
		return Entry{}, fail(CodeAdapter, "mutation response has no metadata", nil)
	}
	responseBytes, err := (proto.MarshalOptions{Deterministic: true}).Marshal(response)
	if err != nil {
		return Entry{}, err
	}
	stateHash, err := c.stateHashLocked(ctx)
	if err != nil {
		return Entry{}, fail(CodeAdapter, "could not confirm post-mutation hash", err)
	}
	return c.cfg.Store.Commit(
		ctx, c.cfg.MatchID, prepared.Entry.Sequence, responseBytes, stateHash.GetStateHash())
}

func (c *Coordinator) ensureRecoveredLocked(ctx context.Context) error {
	_, _, runtimeEpoch := c.cfg.Runtime.RuntimeIdentity()
	if runtimeEpoch == 0 {
		return fail(CodeAdapter, "adapter runtime has no active epoch", nil)
	}
	if c.activeEpoch == runtimeEpoch {
		return nil
	}
	started := time.Now()
	state, err := c.cfg.Store.Load(ctx, c.cfg.MatchID)
	if err != nil {
		c.telemetry.RecoveryFailures++
		return err
	}
	c.nextRequestID = 0
	if state.Checkpoint == nil && len(state.Entries) == 0 {
		c.nextRequestID = c.cfg.InitialRequestID
		c.activeEpoch = runtimeEpoch
		c.telemetry.LastStorageBytes = state.StorageBytes
		return nil
	}
	if runtimeEpoch <= state.LastEpoch {
		c.telemetry.RecoveryFailures++
		return fail(CodeStaleEpoch,
			"durable recovery requires a fresh adapter epoch", nil)
	}
	if state.Checkpoint != nil {
		if err := c.restoreCheckpointLocked(ctx, *state.Checkpoint); err != nil {
			c.telemetry.RecoveryFailures++
			return err
		}
	}
	for _, entry := range state.Entries {
		if entry.Sequence <= state.CheckpointSequence {
			continue
		}
		if err := c.replayEntryLocked(ctx, entry); err != nil {
			c.telemetry.RecoveryFailures++
			return err
		}
		c.telemetry.ReplayedEntries++
	}
	c.activeEpoch = runtimeEpoch
	c.telemetry.Recoveries++
	c.telemetry.LastRecoveryDuration = time.Since(started)
	latest, loadErr := c.cfg.Store.Load(ctx, c.cfg.MatchID)
	if loadErr == nil {
		c.telemetry.LastStorageBytes = latest.StorageBytes
	}
	return nil
}

func (c *Coordinator) restoreCheckpointLocked(ctx context.Context, checkpoint Checkpoint) error {
	request := &adapterv1.RecoverMatchRequest{
		Context: c.nextContextLocked(checkpoint.Tick),
		Checkpoint: &adapterv1.OpaquePayload{
			CodecId: checkpoint.CodecID,
			Value:   append([]byte(nil), checkpoint.Payload...),
		},
	}
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	response, err := c.cfg.Runtime.RecoverMatch(callCtx, request)
	cancel()
	if err != nil {
		return fail(CodeAdapter, "adapter refused checkpoint recovery", err)
	}
	if response.GetMeta().GetCode() != adapterv1.StatusCode_STATUS_OK {
		return fail(CodeAdapter, "adapter rejected checkpoint recovery", nil)
	}
	hash, err := c.stateHashLocked(ctx)
	if err != nil {
		return err
	}
	if hash.GetStateHash() != checkpoint.StateHash {
		return fail(CodeHashMismatch, "checkpoint restored a different state hash", nil)
	}
	return nil
}

func (c *Coordinator) replayEntryLocked(ctx context.Context, entry Entry) error {
	var request proto.Message
	var response proto.Message
	var invoke func(context.Context) error
	switch entry.Operation {
	case OperationApplyCommand:
		typedRequest := new(adapterv1.ApplyCommandRequest)
		typedResponse := new(adapterv1.StatusResponse)
		request, response = typedRequest, typedResponse
		invoke = func(callCtx context.Context) error {
			value, err := c.cfg.Runtime.ApplyCommand(callCtx, typedRequest)
			if err == nil {
				proto.Merge(typedResponse, value)
			}
			return err
		}
	case OperationAdvance:
		typedRequest := new(adapterv1.AdvanceRequest)
		typedResponse := new(adapterv1.AdvanceResponse)
		request, response = typedRequest, typedResponse
		invoke = func(callCtx context.Context) error {
			value, err := c.cfg.Runtime.Advance(callCtx, typedRequest)
			if err == nil {
				proto.Merge(typedResponse, value)
			}
			return err
		}
	default:
		return fail(CodeIncompatible, "journal operation cannot be replayed", nil)
	}
	if err := proto.Unmarshal(entry.Request, request); err != nil {
		return fail(CodeCorrupt, "journal request is malformed", err)
	}
	replaceRequestContext(request, c.nextContextLocked(contextFromRequest(request).GetExpectedTick()))
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	err := invoke(callCtx)
	cancel()
	if err != nil {
		return fail(CodeAdapter, "journal replay RPC failed", err)
	}
	responseBytes, err := (proto.MarshalOptions{Deterministic: true}).Marshal(response)
	if err != nil {
		return err
	}
	hash, err := c.stateHashLocked(ctx)
	if err != nil {
		return err
	}
	if entry.StateHash != "" && hash.GetStateHash() != entry.StateHash {
		return fail(CodeHashMismatch,
			fmt.Sprintf("journal sequence %d replayed to a different hash", entry.Sequence), nil)
	}
	if entry.Committed {
		var durableResponse proto.Message
		switch entry.Operation {
		case OperationApplyCommand:
			durableResponse = new(adapterv1.StatusResponse)
		case OperationAdvance:
			durableResponse = new(adapterv1.AdvanceResponse)
		}
		if err := proto.Unmarshal(entry.Response, durableResponse); err != nil {
			return fail(CodeCorrupt, "durable response is malformed", err)
		}
		if metaFromResponse(durableResponse).GetCode() != metaFromResponse(response).GetCode() {
			return fail(CodeHashMismatch, fmt.Sprintf(
				"replay changed the adapter status from %s to %s (%s)",
				metaFromResponse(durableResponse).GetCode(),
				metaFromResponse(response).GetCode(),
				metaFromResponse(response).GetDetail()), nil)
		}
		return nil
	}
	_, err = c.cfg.Store.Commit(
		ctx, c.cfg.MatchID, entry.Sequence, responseBytes, hash.GetStateHash())
	return err
}

func (c *Coordinator) maybeCheckpointLocked(ctx context.Context, sequence uint64) {
	if c.cfg.CheckpointEvery == 0 || sequence%c.cfg.CheckpointEvery != 0 {
		return
	}
	if err := c.checkpointLocked(ctx, sequence); err != nil {
		c.telemetry.CheckpointFailures++
	}
}

func (c *Coordinator) checkpointLocked(ctx context.Context, sequence uint64) error {
	request := &adapterv1.BuildCheckpointRequest{
		Context: c.nextContextLocked(0),
		CodecId: c.cfg.CodecID,
	}
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	response, err := c.cfg.Runtime.BuildCheckpoint(callCtx, request)
	cancel()
	if err != nil {
		return fail(CodeAdapter, "checkpoint RPC failed", err)
	}
	if response.GetMeta().GetCode() != adapterv1.StatusCode_STATUS_OK ||
		response.GetPayload() == nil {
		return fail(CodeAdapter, "adapter rejected checkpoint creation", nil)
	}
	if err := c.cfg.Store.SaveCheckpoint(ctx, Checkpoint{
		Version: StoreVersion, MatchID: c.cfg.MatchID, Sequence: sequence,
		CodecID:   response.GetPayload().GetCodecId(),
		Payload:   append([]byte(nil), response.GetPayload().GetValue()...),
		StateHash: response.GetStateHash(), Tick: response.GetTick(),
	}); err != nil {
		return err
	}
	c.telemetry.CheckpointsSaved++
	return nil
}

func (c *Coordinator) stateHashLocked(ctx context.Context) (*adapterv1.StateHashResponse, error) {
	callCtx, cancel := context.WithTimeout(ctx, c.cfg.CallTimeout)
	defer cancel()
	return c.cfg.Runtime.GetStateHash(callCtx, &adapterv1.GetStateHashRequest{
		Context: c.nextContextLocked(0),
	})
}

func (c *Coordinator) nextContextLocked(expectedTick uint64) *adapterv1.RequestContext {
	_, instanceID, epoch := c.cfg.Runtime.RuntimeIdentity()
	// ensureRecoveredLocked resets the sequence once when it observes a new
	// epoch. Do not reset here: checkpoint restore and every replayed entry run
	// while activeEpoch still names the prior, successfully recovered epoch.
	c.nextRequestID++
	return &adapterv1.RequestContext{
		Protocol:          &adapterv1.ProtocolVersion{Major: 1, Minor: 0},
		MatchId:           c.cfg.MatchID,
		AdapterInstanceId: instanceID,
		AdapterEpoch:      epoch,
		RequestId:         c.nextRequestID,
		ExpectedTick:      expectedTick,
		DeadlineUnixMs:    uint64(time.Now().Add(c.cfg.CallTimeout).UnixMilli()),
	}
}

func contextFromRequest(message proto.Message) *adapterv1.RequestContext {
	switch request := message.(type) {
	case *adapterv1.ApplyCommandRequest:
		return request.GetContext()
	case *adapterv1.AdvanceRequest:
		return request.GetContext()
	default:
		return nil
	}
}

func replaceRequestContext(message proto.Message, replacement *adapterv1.RequestContext) {
	switch request := message.(type) {
	case *adapterv1.ApplyCommandRequest:
		request.Context = replacement
	case *adapterv1.AdvanceRequest:
		request.Context = replacement
	}
}

func metaFromResponse(message proto.Message) *adapterv1.ResponseMeta {
	switch response := message.(type) {
	case *adapterv1.StatusResponse:
		return response.GetMeta()
	case *adapterv1.AdvanceResponse:
		return response.GetMeta()
	default:
		return nil
	}
}

func clonePayload(value *adapterv1.OpaquePayload) *adapterv1.OpaquePayload {
	if value == nil {
		return nil
	}
	return &adapterv1.OpaquePayload{
		CodecId: value.GetCodecId(),
		Value:   append([]byte(nil), value.GetValue()...),
	}
}
