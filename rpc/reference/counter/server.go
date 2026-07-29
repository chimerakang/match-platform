package counter

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	adapterv1 "github.com/chimerakang/hersir/rpc/gen/go/adapter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/proto"
)

const (
	maxPayloadBytes = 1 << 20
	maxAdvanceTicks = 100
	maxDrainEvents  = 1024
)

type Adapter struct {
	adapterv1.UnimplementedAdapterServiceServer

	mu         sync.Mutex
	instanceID string
	epoch      uint64
	current    *match
	lastMutate uint64
	dedupe     map[uint64]dedupeEntry
}

type dedupeEntry struct {
	digest   [sha256.Size]byte
	response []byte
}

func New(instanceID string, epoch uint64) (*Adapter, error) {
	if strings.TrimSpace(instanceID) == "" || epoch == 0 {
		return nil, fmt.Errorf("adapter instance id and positive epoch are required")
	}
	return &Adapter{
		instanceID: instanceID,
		epoch:      epoch,
		dedupe:     make(map[uint64]dedupeEntry),
	}, nil
}

func (a *Adapter) Negotiate(_ context.Context, request *adapterv1.NegotiateRequest) (*adapterv1.NegotiateResponse, error) {
	response := &adapterv1.NegotiateResponse{Meta: a.topMeta(0)}
	for _, version := range request.GetSupportedProtocols() {
		if version.GetMajor() == 1 {
			response.SelectedProtocol = &adapterv1.ProtocolVersion{Major: 1, Minor: 0}
			response.Capabilities = capabilities()
			response.Limits = &adapterv1.Limits{
				MaxRequestBytes: maxPayloadBytes, MaxResponseBytes: 16 << 20,
				MaxOpaquePayloadBytes: maxPayloadBytes, MaxAdvanceTicks: maxAdvanceTicks,
				MaxEventsPerDrain: maxDrainEvents,
			}
			return response, nil
		}
	}
	response.Meta.Code = adapterv1.StatusCode_STATUS_UNSUPPORTED_PROTOCOL
	response.Meta.Detail = "protocol major 1 is required"
	return response, nil
}

func (a *Adapter) GetDescriptor(_ context.Context, request *adapterv1.GetDescriptorRequest) (*adapterv1.GetDescriptorResponse, error) {
	meta := a.validateTop(request.GetProtocol(), request.GetRequestId(), request.GetDeadlineUnixMs())
	response := &adapterv1.GetDescriptorResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	slotPolicy := mustJSON(struct {
		Participants int  `json:"participants"`
		Observers    bool `json:"observers"`
	}{3, true})
	response.Descriptor_ = &adapterv1.PackageDescriptor{
		GameId: GameID, AdapterVersion: AdapterVersion,
		ContentVersions: []string{ContentVersion}, ContentHashes: []string{contentHash()},
		CodecIds: []string{CodecID}, TickRate: TickRate, Capabilities: capabilities(),
		SlotPolicy: payload(slotPolicy),
	}
	return response, nil
}

func (a *Adapter) GetSlotDescriptors(_ context.Context, request *adapterv1.GetSlotDescriptorsRequest) (*adapterv1.GetSlotDescriptorsResponse, error) {
	meta := a.validateTop(request.GetProtocol(), request.GetRequestId(), request.GetDeadlineUnixMs())
	response := &adapterv1.GetSlotDescriptorsResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	for _, slot := range participantSlots {
		response.Slots = append(response.Slots, payload(mustJSON(struct {
			SlotID   string `json:"slot_id"`
			Kind     string `json:"kind"`
			Fillable bool   `json:"fillable"`
		}{slot, "participant", true})))
	}
	response.Slots = append(response.Slots, payload(mustJSON(struct {
		SlotID   string `json:"slot_id"`
		Kind     string `json:"kind"`
		Fillable bool   `json:"fillable"`
	}{"observer", "observer", false})))
	return response, nil
}

func (a *Adapter) ValidateMatchConfig(_ context.Context, request *adapterv1.ValidateMatchConfigRequest) (*adapterv1.StatusResponse, error) {
	meta := a.validateTop(request.GetProtocol(), request.GetRequestId(), request.GetDeadlineUnixMs())
	response := &adapterv1.StatusResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	_, _, err := decodeConfig(request.GetConfig())
	if err != nil {
		reject(meta, err.Error())
	}
	return response, nil
}

func (a *Adapter) CreateMatch(_ context.Context, request *adapterv1.CreateMatchRequest) (*adapterv1.MatchResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if response, found := dedupeResponse[*adapterv1.MatchResponse](a, request); found {
		return response, nil
	}
	meta := a.validateContextLocked(request.GetContext(), false)
	response := &adapterv1.MatchResponse{Meta: meta}
	defer a.remember(request, response)
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	if request.GetContext().GetRequestId() <= a.lastMutate {
		response.Meta = a.errorMeta(request.GetContext().GetRequestId(),
			adapterv1.StatusCode_STATUS_OUT_OF_ORDER,
			"mutation request_id must increase within the epoch")
		return response, nil
	}
	a.lastMutate = request.GetContext().GetRequestId()
	matchID, limit, err := decodeConfig(request.GetConfig())
	if err != nil {
		reject(meta, err.Error())
		return response, nil
	}
	if matchID == "" {
		matchID = fmt.Sprintf("counter:%d", request.GetSeed())
	}
	if matchID != request.GetContext().GetMatchId() {
		reject(meta, "config match_id differs from request context")
		return response, nil
	}
	a.current = newMatch(matchID, request.GetSeed(), limit)
	a.dedupe = make(map[uint64]dedupeEntry)
	response.MatchId = matchID
	return response, nil
}

func (a *Adapter) RecoverMatch(_ context.Context, request *adapterv1.RecoverMatchRequest) (*adapterv1.MatchResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if response, found := dedupeResponse[*adapterv1.MatchResponse](a, request); found {
		return response, nil
	}
	meta := a.validateContextLocked(request.GetContext(), false)
	response := &adapterv1.MatchResponse{Meta: meta}
	defer a.remember(request, response)
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	if request.GetContext().GetRequestId() <= a.lastMutate {
		response.Meta = a.errorMeta(request.GetContext().GetRequestId(),
			adapterv1.StatusCode_STATUS_OUT_OF_ORDER,
			"mutation request_id must increase within the epoch")
		return response, nil
	}
	a.lastMutate = request.GetContext().GetRequestId()
	var value checkpoint
	if err := decode(request.GetCheckpoint(), &value); err != nil {
		reject(meta, err.Error())
		return response, nil
	}
	restored, err := recoverMatch(value)
	if err != nil || restored.id != request.GetContext().GetMatchId() {
		if err == nil {
			err = fmt.Errorf("checkpoint match_id differs from request context")
		}
		reject(meta, err.Error())
		return response, nil
	}
	a.current = restored
	a.dedupe = make(map[uint64]dedupeEntry)
	response.MatchId = restored.id
	response.Meta.ObservedTick = restored.state.Step
	return response, nil
}

func (a *Adapter) ValidateJoin(_ context.Context, request *adapterv1.ValidateJoinRequest) (*adapterv1.ValidateJoinResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.ValidateJoinResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	switch request.GetRole() {
	case "observer":
		response.AssignedSlot = payload(mustJSON("observer"))
	case "participant":
		var requested string
		if value := request.GetRequestedSlot(); value != nil && len(value.GetValue()) > 0 &&
			string(value.GetValue()) != "null" {
			if err := decode(value, &requested); err != nil {
				reject(meta, "requested slot is invalid")
				return response, nil
			}
		}
		if requested == "" {
			requested = participantSlots[0]
		}
		if !isParticipant(requested) {
			reject(meta, "slot is not part of this package")
			return response, nil
		}
		response.AssignedSlot = payload(mustJSON(requested))
	default:
		reject(meta, "role is not supported")
	}
	return response, nil
}

func (a *Adapter) ValidateCommand(_ context.Context, request *adapterv1.ValidateCommandRequest) (*adapterv1.StatusResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.StatusResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	slot, command, err := decodeCommand(request.GetSlot(), request.GetCommand())
	if err == nil {
		_, err = a.current.validateCommand(slot, command)
	}
	if err != nil {
		reject(meta, err.Error())
	}
	return response, nil
}

func (a *Adapter) ApplyCommand(_ context.Context, request *adapterv1.ApplyCommandRequest) (*adapterv1.StatusResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if response, found := dedupeResponse[*adapterv1.StatusResponse](a, request); found {
		return response, nil
	}
	meta := a.validateMutationLocked(request.GetContext())
	response := &adapterv1.StatusResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK {
		slot, command, err := decodeCommand(request.GetSlot(), request.GetCommand())
		if err == nil {
			err = a.current.apply(slot, command)
		}
		if err != nil {
			reject(meta, err.Error())
		}
	}
	a.remember(request, response)
	return response, nil
}

func (a *Adapter) Advance(_ context.Context, request *adapterv1.AdvanceRequest) (*adapterv1.AdvanceResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if response, found := dedupeResponse[*adapterv1.AdvanceResponse](a, request); found {
		return response, nil
	}
	meta := a.validateMutationLocked(request.GetContext())
	response := &adapterv1.AdvanceResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK {
		if request.GetTicks() > maxAdvanceTicks {
			meta.Code = adapterv1.StatusCode_STATUS_INVALID_ARGUMENT
			meta.Detail = "advance exceeds negotiated tick limit"
		} else {
			a.current.advance(request.GetTicks())
			meta.ObservedTick = a.current.state.Step
			response.Tick = a.current.state.Step
		}
	}
	a.remember(request, response)
	return response, nil
}

func (a *Adapter) GetTerminalResult(_ context.Context, request *adapterv1.GetTerminalResultRequest) (*adapterv1.OpaqueResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.OpaqueResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK && a.current.state.Completion != nil {
		response.Present = true
		response.Payload = payload(mustJSON(a.current.state.Completion))
	}
	return response, nil
}

func (a *Adapter) GetStateHash(_ context.Context, request *adapterv1.GetStateHashRequest) (*adapterv1.StateHashResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.StateHashResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK {
		response.StateHash = a.current.stateHash()
		response.Tick = a.current.state.Step
	}
	return response, nil
}

func (a *Adapter) ExportReplay(_ context.Context, request *adapterv1.ExportReplayRequest) (*adapterv1.OpaqueResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.OpaqueResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK {
		response.Present = true
		response.Payload = payload(mustJSON(replay{
			Schema: 1, GameID: GameID, MatchID: a.current.id, Seed: a.current.state.Seed,
			Limit: a.current.state.Limit, Log: nonNilLog(a.current.log),
			Steps: a.current.state.Step, StateHash: a.current.stateHash(),
			Completion: a.current.state.Completion,
		}))
	}
	return response, nil
}

func (a *Adapter) BuildCheckpoint(_ context.Context, request *adapterv1.BuildCheckpointRequest) (*adapterv1.CheckpointResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.CheckpointResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	if request.GetCodecId() != CodecID {
		reject(meta, "unsupported checkpoint codec")
		return response, nil
	}
	a.current.checkpoints++
	response.Payload = payload(mustJSON(checkpoint{
		GameID: GameID, MatchID: a.current.id, State: a.current.state,
		Log: nonNilLog(a.current.log),
	}))
	response.StateHash = a.current.stateHash()
	response.Tick = a.current.state.Step
	return response, nil
}

func (a *Adapter) BuildDelta(_ context.Context, request *adapterv1.BuildDeltaRequest) (*adapterv1.DeltaResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.DeltaResponse{Meta: meta}
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	if request.GetCodecId() != CodecID {
		reject(meta, "unsupported delta codec")
		return response, nil
	}
	if _, exists := a.current.history[request.GetFromAckTick()]; !exists ||
		request.GetFromAckTick() >= a.current.state.Step {
		meta.Code = adapterv1.StatusCode_STATUS_NOT_FOUND
		meta.Detail = "delta base tick is unavailable"
		return response, nil
	}
	a.current.increments++
	response.Payload = payload(mustJSON(delta{Replace: a.current.state}))
	response.Tick = a.current.state.Step
	response.BaseTick = request.GetFromAckTick()
	return response, nil
}

func (a *Adapter) DrainEvents(_ context.Context, request *adapterv1.DrainEventsRequest) (*adapterv1.DrainEventsResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if response, found := dedupeResponse[*adapterv1.DrainEventsResponse](a, request); found {
		return response, nil
	}
	meta := a.validateMutationLocked(request.GetContext())
	response := &adapterv1.DrainEventsResponse{Meta: meta}
	defer a.remember(request, response)
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return response, nil
	}
	if request.GetCodecId() != CodecID {
		reject(meta, "unsupported event codec")
		return response, nil
	}
	limit := int(request.GetMaxEvents())
	if limit == 0 || limit > maxDrainEvents {
		limit = maxDrainEvents
	}
	for a.current.eventCursor < len(a.current.events) && len(response.Events) < limit {
		event := a.current.events[a.current.eventCursor]
		response.Events = append(response.Events, &adapterv1.AdapterEvent{
			Reliability: adapterv1.Reliability_RELIABILITY_RELIABLE,
			Payload:     payload(mustJSON(event)),
		})
		a.current.eventCursor++
	}
	return response, nil
}

func (a *Adapter) GetMetrics(_ context.Context, request *adapterv1.GetMetricsRequest) (*adapterv1.MetricsResponse, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	meta := a.validateContextLocked(request.GetContext(), true)
	response := &adapterv1.MetricsResponse{Meta: meta}
	if meta.Code == adapterv1.StatusCode_STATUS_OK {
		response.Metrics = []*adapterv1.Metric{
			{Name: "accepted", Value: float64(a.current.accepted)},
			{Name: "refused", Value: float64(a.current.refused)},
			{Name: "checkpoints", Value: float64(a.current.checkpoints)},
			{Name: "increments", Value: float64(a.current.increments)},
			{Name: "step", Value: float64(a.current.state.Step)},
		}
	}
	return response, nil
}

func (a *Adapter) Health(_ context.Context, request *adapterv1.HealthRequest) (*adapterv1.HealthResponse, error) {
	meta := a.validateTop(request.GetProtocol(), request.GetRequestId(), request.GetDeadlineUnixMs())
	status := adapterv1.ServingStatus_SERVING
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		status = adapterv1.ServingStatus_NOT_SERVING
	}
	return &adapterv1.HealthResponse{Meta: meta, Status: status}, nil
}

func (a *Adapter) validateTop(version *adapterv1.ProtocolVersion, requestID, deadline uint64) *adapterv1.ResponseMeta {
	meta := a.topMeta(requestID)
	if version.GetMajor() != 1 {
		meta.Code = adapterv1.StatusCode_STATUS_UNSUPPORTED_PROTOCOL
		meta.Detail = "protocol major 1 is required"
	} else if deadline > 0 && deadline < uint64(time.Now().UnixMilli()) {
		meta.Code = adapterv1.StatusCode_STATUS_DEADLINE_EXCEEDED
		meta.Detail = "request deadline has elapsed"
	}
	return meta
}

func (a *Adapter) validateContextLocked(value *adapterv1.RequestContext, requireMatch bool) *adapterv1.ResponseMeta {
	if value == nil {
		return a.errorMeta(0, adapterv1.StatusCode_STATUS_INVALID_ARGUMENT, "request context is required")
	}
	meta := a.validateTop(value.GetProtocol(), value.GetRequestId(), value.GetDeadlineUnixMs())
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return meta
	}
	if subtle.ConstantTimeCompare([]byte(value.GetAdapterInstanceId()), []byte(a.instanceID)) != 1 ||
		value.GetAdapterEpoch() != a.epoch {
		return a.errorMeta(value.GetRequestId(), adapterv1.StatusCode_STATUS_STALE_EPOCH,
			"adapter identity or epoch is stale")
	}
	if requireMatch {
		if a.current == nil || value.GetMatchId() != a.current.id {
			return a.errorMeta(value.GetRequestId(), adapterv1.StatusCode_STATUS_NOT_FOUND,
				"match is not loaded")
		}
		meta.ObservedTick = a.current.state.Step
		if value.GetExpectedTick() != 0 && value.GetExpectedTick() != a.current.state.Step {
			return a.errorMeta(value.GetRequestId(), adapterv1.StatusCode_STATUS_OUT_OF_ORDER,
				"expected tick differs from authoritative tick")
		}
	}
	return meta
}

func (a *Adapter) validateMutationLocked(value *adapterv1.RequestContext) *adapterv1.ResponseMeta {
	meta := a.validateContextLocked(value, true)
	if meta.Code != adapterv1.StatusCode_STATUS_OK {
		return meta
	}
	if value.GetRequestId() <= a.lastMutate {
		return a.errorMeta(value.GetRequestId(), adapterv1.StatusCode_STATUS_OUT_OF_ORDER,
			fmt.Sprintf("mutation request_id %d must exceed %d within the epoch",
				value.GetRequestId(), a.lastMutate))
	}
	a.lastMutate = value.GetRequestId()
	return meta
}

func (a *Adapter) topMeta(requestID uint64) *adapterv1.ResponseMeta {
	return &adapterv1.ResponseMeta{
		Code: adapterv1.StatusCode_STATUS_OK, RequestId: requestID,
		AdapterInstanceId: a.instanceID, AdapterEpoch: a.epoch,
	}
}

func (a *Adapter) errorMeta(requestID uint64, code adapterv1.StatusCode, detail string) *adapterv1.ResponseMeta {
	meta := a.topMeta(requestID)
	meta.Code, meta.Detail = code, detail
	return meta
}

func reject(meta *adapterv1.ResponseMeta, detail string) {
	meta.Code = adapterv1.StatusCode_STATUS_ADAPTER_REJECTED
	meta.Detail = detail
}

func capabilities() []*adapterv1.Capability {
	return []*adapterv1.Capability{
		{Name: "checkpoint", Version: 1}, {Name: "delta", Version: 1},
		{Name: "events", Version: 1}, {Name: "replay", Version: 1},
	}
}

func payload(value []byte) *adapterv1.OpaquePayload {
	return &adapterv1.OpaquePayload{CodecId: CodecID, Value: value}
}

func decode(value *adapterv1.OpaquePayload, destination any) error {
	if value == nil || value.GetCodecId() != CodecID {
		return fmt.Errorf("payload must use %s", CodecID)
	}
	if len(value.GetValue()) > maxPayloadBytes {
		return fmt.Errorf("payload exceeds negotiated limit")
	}
	if err := json.Unmarshal(value.GetValue(), destination); err != nil {
		return fmt.Errorf("payload is not valid JSON: %w", err)
	}
	return nil
}

func decodeConfig(value *adapterv1.OpaquePayload) (string, int, error) {
	var candidate *struct {
		MatchID string `json:"match_id"`
		Limit   int    `json:"limit"`
	}
	if err := decode(value, &candidate); err != nil {
		return "", 0, err
	}
	if candidate == nil {
		return "", 0, fmt.Errorf("match config must be a JSON object")
	}
	if candidate.Limit == 0 {
		candidate.Limit = 8
	}
	if candidate.Limit < 2 || candidate.Limit > 100 {
		return "", 0, fmt.Errorf("limit must be between 2 and 100")
	}
	return candidate.MatchID, candidate.Limit, nil
}

func decodeCommand(slotPayload, commandPayload *adapterv1.OpaquePayload) (string, command, error) {
	var slot string
	if err := decode(slotPayload, &slot); err != nil {
		return "", command{}, err
	}
	var candidate struct {
		Action string `json:"action"`
		Amount *int   `json:"amount"`
	}
	if err := decode(commandPayload, &candidate); err != nil {
		return "", command{}, err
	}
	amount := 1
	if candidate.Amount != nil {
		amount = *candidate.Amount
	}
	return slot, command{Action: candidate.Action, Amount: amount}, nil
}

func mustJSON(value any) []byte {
	result, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return result
}

func nonNilLog(value []commandEntry) []commandEntry {
	if value == nil {
		return []commandEntry{}
	}
	return value
}

func (a *Adapter) remember(request proto.Message, response proto.Message) {
	context := mutationContext(request)
	if context == nil {
		return
	}
	if _, exists := a.dedupe[context.GetRequestId()]; exists {
		// A conflicting reuse must never replace the original response retained
		// for the byte-identical retry.
		return
	}
	requestBytes, _ := (proto.MarshalOptions{Deterministic: true}).Marshal(request)
	responseBytes, _ := (proto.MarshalOptions{Deterministic: true}).Marshal(response)
	a.dedupe[context.GetRequestId()] = dedupeEntry{
		digest: sha256.Sum256(requestBytes), response: responseBytes,
	}
}

func dedupeResponse[T proto.Message](a *Adapter, request proto.Message) (T, bool) {
	var zero T
	context := mutationContext(request)
	if context == nil {
		return zero, false
	}
	entry, found := a.dedupe[context.GetRequestId()]
	if !found {
		return zero, false
	}
	requestBytes, _ := (proto.MarshalOptions{Deterministic: true}).Marshal(request)
	if entry.digest != sha256.Sum256(requestBytes) {
		return zero, false
	}
	response := zero.ProtoReflect().Type().New().Interface().(T)
	if proto.Unmarshal(entry.response, response) != nil {
		return zero, false
	}
	return response, true
}

func mutationContext(request proto.Message) *adapterv1.RequestContext {
	switch value := request.(type) {
	case *adapterv1.CreateMatchRequest:
		return value.GetContext()
	case *adapterv1.RecoverMatchRequest:
		return value.GetContext()
	case *adapterv1.ApplyCommandRequest:
		return value.GetContext()
	case *adapterv1.AdvanceRequest:
		return value.GetContext()
	case *adapterv1.DrainEventsRequest:
		return value.GetContext()
	default:
		return nil
	}
}

type RunConfig struct {
	Endpoint   string
	InstanceID string
	Epoch      uint64
	TLSConfig  *tls.Config
}

func Run(ctx context.Context, config RunConfig) error {
	adapter, err := New(config.InstanceID, config.Epoch)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", config.Endpoint)
	if err != nil {
		return err
	}
	options := []grpc.ServerOption{
		grpc.MaxRecvMsgSize(maxPayloadBytes),
		grpc.MaxSendMsgSize(16 << 20),
	}
	if config.TLSConfig != nil {
		options = append(options, grpc.Creds(credentials.NewTLS(config.TLSConfig)))
	}
	server := grpc.NewServer(options...)
	adapterv1.RegisterAdapterServiceServer(server, adapter)
	go func() {
		<-ctx.Done()
		server.GracefulStop()
	}()
	return server.Serve(listener)
}

func RunFromEnvironment(ctx context.Context) error {
	epoch, err := strconv.ParseUint(os.Getenv("HERSIR_ADAPTER_EPOCH"), 10, 64)
	if err != nil {
		return fmt.Errorf("HERSIR_ADAPTER_EPOCH must be a positive integer: %w", err)
	}
	tlsConfig, err := tlsConfigFromEnvironment()
	if err != nil {
		return err
	}
	return Run(ctx, RunConfig{
		Endpoint:   os.Getenv("HERSIR_ADAPTER_RPC_ENDPOINT"),
		InstanceID: os.Getenv("HERSIR_ADAPTER_INSTANCE_ID"),
		Epoch:      epoch,
		TLSConfig:  tlsConfig,
	})
}

func tlsConfigFromEnvironment() (*tls.Config, error) {
	certPath := os.Getenv("HERSIR_ADAPTER_TLS_CERT")
	keyPath := os.Getenv("HERSIR_ADAPTER_TLS_KEY")
	caPath := os.Getenv("HERSIR_ADAPTER_CLIENT_CA")
	if certPath == "" && keyPath == "" && caPath == "" {
		return nil, nil
	}
	if certPath == "" || keyPath == "" || caPath == "" {
		return nil, fmt.Errorf(
			"HERSIR_ADAPTER_TLS_CERT, HERSIR_ADAPTER_TLS_KEY and HERSIR_ADAPTER_CLIENT_CA must be set together")
	}
	certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("load adapter TLS key pair: %w", err)
	}
	caBytes, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("read adapter client CA: %w", err)
	}
	clientCAs := x509.NewCertPool()
	if !clientCAs.AppendCertsFromPEM(caBytes) {
		return nil, fmt.Errorf("adapter client CA contains no certificates")
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{certificate},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    clientCAs,
	}, nil
}
