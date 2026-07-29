package runtime

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	adapterv1 "github.com/chimerakang/hersir/rpc/gen/go/adapter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type responseWithMeta interface {
	GetMeta() *adapterv1.ResponseMeta
}

type requestWithDeadline interface {
	GetDeadlineUnixMs() uint64
}

type requestWithContext interface {
	GetContext() *adapterv1.RequestContext
}

// ProcessRuntime is a one-adapter failure domain. It implements the complete
// generated AdapterServiceClient surface while supervising the endpoint process.
type ProcessRuntime struct {
	cfg       Config
	runtimeID string

	mu         sync.Mutex
	rootCtx    context.Context
	rootCancel context.CancelFunc
	cmd        *exec.Cmd
	conn       *grpc.ClientConn
	client     adapterv1.AdapterServiceClient
	instanceID string
	epoch      uint64
	ready      bool
	draining   bool
	closed     bool
	restarts   int
	generation uint64
	active     sync.WaitGroup
	slots      chan struct{}
	workers    chan struct{}

	consecutiveFailures int
	circuitOpenUntil    time.Time
	telemetry           *telemetryState
}

var _ adapterv1.AdapterServiceClient = (*ProcessRuntime)(nil)

func NewProcessRuntime(cfg Config) (*ProcessRuntime, error) {
	cfg.withDefaults()
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	runtimeID, err := randomID("runtime")
	if err != nil {
		return nil, err
	}
	return &ProcessRuntime{
		cfg:       cfg,
		runtimeID: runtimeID,
		slots:     make(chan struct{}, cfg.MaxConcurrent+cfg.QueueCapacity),
		workers:   make(chan struct{}, cfg.MaxConcurrent),
		telemetry: newTelemetry(cfg.AdapterPackage, runtimeID),
	}, nil
}

func (r *ProcessRuntime) RuntimeIdentity() (runtimeID, instanceID string, epoch uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.runtimeID, r.instanceID, r.epoch
}

func (r *ProcessRuntime) Telemetry() Telemetry {
	return r.telemetry.snapshot()
}

func (r *ProcessRuntime) Start(ctx context.Context) error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return failure(CodeUnavailable, "runtime is closed", false, nil)
	}
	if r.rootCancel != nil {
		r.mu.Unlock()
		return nil
	}
	r.rootCtx, r.rootCancel = context.WithCancel(context.Background())
	r.mu.Unlock()

	if err := r.startGeneration(); err != nil {
		r.mu.Lock()
		if r.rootCancel != nil {
			r.rootCancel()
			r.rootCancel = nil
		}
		r.mu.Unlock()
		return err
	}
	readyCtx, cancel := withCallDeadline(ctx, r.cfg.ReadyTimeout)
	defer cancel()
	if err := r.AwaitReady(readyCtx); err != nil {
		_ = r.Close()
		return err
	}
	return nil
}

func (r *ProcessRuntime) startGeneration() error {
	instanceID, err := randomID("adapter")
	if err != nil {
		return err
	}

	r.mu.Lock()
	if r.closed || r.draining || r.rootCtx == nil || r.rootCtx.Err() != nil {
		r.mu.Unlock()
		return failure(CodeUnavailable, "runtime is stopping", false, nil)
	}
	r.epoch++
	r.generation++
	generation := r.generation
	epoch := r.epoch
	r.instanceID = instanceID
	r.ready = false
	command := exec.CommandContext(r.rootCtx, r.cfg.Process.Command, r.cfg.Process.Args...)
	command.Dir = r.cfg.Process.Dir
	command.Env = append(os.Environ(), r.cfg.Process.Env...)
	command.Env = append(command.Env,
		"HERSIR_ADAPTER_RPC_ENDPOINT="+r.cfg.Endpoint,
		"HERSIR_ADAPTER_INSTANCE_ID="+instanceID,
		fmt.Sprintf("HERSIR_ADAPTER_EPOCH=%d", epoch),
		"HERSIR_PLATFORM_WORKLOAD_IDENTITY="+r.cfg.WorkloadIdentity,
	)
	if err := command.Start(); err != nil {
		r.mu.Unlock()
		return failure(CodeUnavailable, "could not start adapter process", true, err)
	}
	r.cmd = command
	r.telemetry.mu.Lock()
	r.telemetry.v.AdapterEpoch = epoch
	r.telemetry.v.ProcessStarts++
	r.telemetry.mu.Unlock()
	r.mu.Unlock()

	go r.watchProcess(command, generation)
	go r.connectGeneration(generation, epoch)
	return nil
}

func (r *ProcessRuntime) connectGeneration(generation, epoch uint64) {
	options := []grpc.DialOption{
		grpc.WithDefaultCallOptions(
			grpc.MaxCallRecvMsgSize(r.cfg.MaxResponseBytes),
			grpc.MaxCallSendMsgSize(r.cfg.MaxRequestBytes),
		),
	}
	if r.cfg.Credentials != nil {
		options = append(options, grpc.WithTransportCredentials(r.cfg.Credentials))
	} else {
		options = append(options, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}
	conn, err := grpc.NewClient(r.cfg.Endpoint, options...)
	if err != nil {
		return
	}
	client := adapterv1.NewAdapterServiceClient(conn)
	deadline := time.Now().Add(r.cfg.ReadyTimeout)
	for time.Now().Before(deadline) {
		r.mu.Lock()
		valid := !r.closed && !r.draining && r.generation == generation
		r.mu.Unlock()
		if !valid {
			_ = conn.Close()
			return
		}
		callCtx, cancel := context.WithTimeout(context.Background(), r.cfg.HealthInterval)
		response, healthErr := client.Health(callCtx, &adapterv1.HealthRequest{
			Protocol:       &adapterv1.ProtocolVersion{Major: 1, Minor: 0},
			RequestId:      1,
			DeadlineUnixMs: uint64(time.Now().Add(r.cfg.HealthInterval).UnixMilli()),
		})
		cancel()
		if healthErr == nil && response.GetStatus() == adapterv1.ServingStatus_SERVING {
			r.mu.Lock()
			if !r.closed && !r.draining && r.generation == generation && r.epoch == epoch {
				oldConn := r.conn
				r.conn = conn
				r.client = client
				r.ready = true
				r.mu.Unlock()
				if oldConn != nil {
					_ = oldConn.Close()
				}
				go r.monitorGeneration(generation, client)
				return
			}
			r.mu.Unlock()
			_ = conn.Close()
			return
		}
		time.Sleep(r.cfg.HealthInterval)
	}
	_ = conn.Close()
}

func (r *ProcessRuntime) monitorGeneration(
	generation uint64, client adapterv1.AdapterServiceClient,
) {
	ticker := time.NewTicker(r.cfg.LivenessInterval)
	defer ticker.Stop()
	failures := 0
	for range ticker.C {
		r.mu.Lock()
		valid := !r.closed && !r.draining && r.ready && r.generation == generation
		command := r.cmd
		r.mu.Unlock()
		if !valid {
			return
		}
		callCtx, cancel := context.WithTimeout(context.Background(), r.cfg.HealthInterval)
		response, err := client.Health(callCtx, &adapterv1.HealthRequest{
			Protocol:       &adapterv1.ProtocolVersion{Major: 1, Minor: 0},
			RequestId:      uint64(time.Now().UnixNano()),
			DeadlineUnixMs: uint64(time.Now().Add(r.cfg.HealthInterval).UnixMilli()),
		})
		cancel()
		if err == nil && response.GetStatus() == adapterv1.ServingStatus_SERVING {
			failures = 0
			continue
		}
		failures++
		if failures < r.cfg.LivenessFailures {
			continue
		}
		if command != nil && command.Process != nil {
			_ = command.Process.Kill()
		}
		return
	}
}

func (r *ProcessRuntime) watchProcess(command *exec.Cmd, generation uint64) {
	err := command.Wait()
	r.mu.Lock()
	if r.generation != generation {
		r.mu.Unlock()
		return
	}
	r.ready = false
	if r.conn != nil {
		_ = r.conn.Close()
		r.conn = nil
		r.client = nil
	}
	shouldRestart := !r.closed && !r.draining && r.rootCtx != nil && r.rootCtx.Err() == nil &&
		r.restarts < r.cfg.Restart.MaxRestarts
	if err != nil && shouldRestart {
		r.telemetry.mu.Lock()
		r.telemetry.v.ProcessCrashes++
		r.telemetry.mu.Unlock()
	}
	if shouldRestart {
		r.restarts++
		r.telemetry.mu.Lock()
		r.telemetry.v.Restarts++
		r.telemetry.mu.Unlock()
	}
	r.mu.Unlock()
	if shouldRestart {
		time.Sleep(r.cfg.Restart.Backoff)
		_ = r.startGeneration()
	}
}

func (r *ProcessRuntime) AwaitReady(ctx context.Context) error {
	ticker := time.NewTicker(r.cfg.HealthInterval)
	defer ticker.Stop()
	for {
		r.mu.Lock()
		ready, closed := r.ready, r.closed
		r.mu.Unlock()
		if ready {
			return nil
		}
		if closed {
			return failure(CodeUnavailable, "runtime closed before readiness", false, nil)
		}
		select {
		case <-ctx.Done():
			return contextFailure(ctx.Err())
		case <-ticker.C:
		}
	}
}

// Kill is an operations/fault-injection hook. The watcher applies the configured
// restart policy and increments the epoch before accepting new calls.
func (r *ProcessRuntime) Kill() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cmd == nil || r.cmd.Process == nil {
		return failure(CodeUnavailable, "adapter process is not running", true, nil)
	}
	return r.cmd.Process.Kill()
}

func (r *ProcessRuntime) Drain(ctx context.Context) error {
	r.mu.Lock()
	if r.draining || r.closed {
		r.mu.Unlock()
		return nil
	}
	r.draining = true
	r.ready = false
	r.mu.Unlock()

	done := make(chan struct{})
	go func() {
		r.active.Wait()
		close(done)
	}()
	drainCtx, cancel := withCallDeadline(ctx, r.cfg.DrainTimeout)
	defer cancel()
	select {
	case <-drainCtx.Done():
		_ = r.Close()
		return contextFailure(drainCtx.Err())
	case <-done:
	}
	return r.Close()
}

func (r *ProcessRuntime) Close() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	r.ready = false
	if r.rootCancel != nil {
		r.rootCancel()
	}
	conn := r.conn
	r.conn = nil
	r.client = nil
	command := r.cmd
	r.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	if command != nil && command.Process != nil {
		_ = command.Process.Kill()
	}
	return nil
}

func (r *ProcessRuntime) invoke(
	ctx context.Context,
	operation string,
	request proto.Message,
	response proto.Message,
	call func(context.Context, adapterv1.AdapterServiceClient) error,
) error {
	started := time.Now()
	if proto.Size(request) > r.cfg.MaxRequestBytes {
		return r.recordFailure(operation, started, CodePayloadTooLarge,
			"request exceeds configured uncompressed limit", false, nil)
	}
	if deadline, ok := rpcDeadline(request); ok && !deadline.After(time.Now()) {
		return r.recordFailure(operation, started, CodeDeadlineExceeded,
			"request absolute deadline has expired", false, nil)
	}
	select {
	case r.slots <- struct{}{}:
	default:
		r.telemetry.mu.Lock()
		r.telemetry.v.QueueRejected++
		r.telemetry.mu.Unlock()
		return r.recordFailure(operation, started, CodeResourceExhausted,
			"adapter queue is saturated", true, nil)
	}
	defer func() {
		<-r.slots
		r.updateCapacityTelemetry()
	}()
	r.updateCapacityTelemetry()

	callCtx, cancel := withRPCDeadline(ctx, request, r.cfg.CallTimeout)
	defer cancel()
	select {
	case r.workers <- struct{}{}:
	case <-callCtx.Done():
		return r.recordFailure(operation, started, classifyContext(callCtx.Err()),
			"call expired while waiting for adapter capacity", false, callCtx.Err())
	}
	defer func() {
		<-r.workers
		r.updateCapacityTelemetry()
	}()
	r.updateCapacityTelemetry()

	r.mu.Lock()
	if r.closed || r.draining {
		r.mu.Unlock()
		return r.recordFailure(operation, started, CodeUnavailable,
			"adapter runtime is draining", false, nil)
	}
	if time.Now().Before(r.circuitOpenUntil) {
		r.mu.Unlock()
		return r.recordFailure(operation, started, CodeCircuitOpen,
			"adapter circuit breaker is open", true, nil)
	}
	client, epoch, ready := r.client, r.epoch, r.ready
	if !ready || client == nil {
		r.mu.Unlock()
		return r.recordFailure(operation, started, CodeUnavailable,
			"adapter endpoint is unavailable", true, nil)
	}
	r.active.Add(1)
	r.mu.Unlock()
	defer r.active.Done()

	r.telemetry.mu.Lock()
	r.telemetry.v.InFlight++
	r.telemetry.mu.Unlock()
	defer func() {
		r.telemetry.mu.Lock()
		r.telemetry.v.InFlight--
		r.telemetry.mu.Unlock()
	}()

	err := call(callCtx, client)
	if err != nil {
		code := classifyRPC(err)
		// A caller-initiated cancellation says nothing about adapter health.
		if code != CodeCancelled {
			r.noteTransportFailure()
		}
		return r.recordFailure(operation, started, code, "adapter RPC failed", retryable(code), err)
	}
	if response == nil || proto.Size(response) > r.cfg.MaxResponseBytes {
		r.noteTransportFailure()
		return r.recordFailure(operation, started, CodePayloadTooLarge,
			"response exceeds configured uncompressed limit", false, nil)
	}
	withMeta, ok := response.(responseWithMeta)
	if !ok || withMeta.GetMeta() == nil {
		r.noteTransportFailure()
		return r.recordFailure(operation, started, CodeMalformedReply,
			"response is missing required metadata", false, nil)
	}
	meta := withMeta.GetMeta()
	r.mu.Lock()
	stale := epoch != r.epoch ||
		(meta.GetAdapterEpoch() != 0 && meta.GetAdapterEpoch() != epoch) ||
		(meta.GetAdapterInstanceId() != "" && meta.GetAdapterInstanceId() != r.instanceID)
	r.mu.Unlock()
	if stale {
		r.noteTransportFailure()
		return r.recordFailure(operation, started, CodeStaleEpoch,
			"response belongs to a prior adapter epoch", false, nil)
	}
	r.noteSuccess()
	r.recordSuccess(operation, started)
	return nil
}

func rpcDeadline(request proto.Message) (time.Time, bool) {
	var unixMillis uint64
	if withContext, ok := request.(requestWithContext); ok && withContext.GetContext() != nil {
		unixMillis = withContext.GetContext().GetDeadlineUnixMs()
	} else if withDeadline, ok := request.(requestWithDeadline); ok {
		unixMillis = withDeadline.GetDeadlineUnixMs()
	}
	if unixMillis == 0 {
		return time.Time{}, false
	}
	return time.UnixMilli(int64(unixMillis)), true
}

func withRPCDeadline(
	parent context.Context, request proto.Message, maximum time.Duration,
) (context.Context, context.CancelFunc) {
	if rpcLimit, ok := rpcDeadline(request); ok {
		if parentLimit, hasParentLimit := parent.Deadline(); !hasParentLimit || rpcLimit.Before(parentLimit) {
			limited, cancel := context.WithDeadline(parent, rpcLimit)
			if time.Until(rpcLimit) <= maximum {
				return limited, cancel
			}
			cancel()
		}
	}
	return withCallDeadline(parent, maximum)
}

func (r *ProcessRuntime) updateCapacityTelemetry() {
	queueDepth := len(r.slots) - len(r.workers)
	if queueDepth < 0 {
		queueDepth = 0
	}
	r.telemetry.mu.Lock()
	r.telemetry.v.QueueDepth = queueDepth
	r.telemetry.mu.Unlock()
}

func (r *ProcessRuntime) noteTransportFailure() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.consecutiveFailures++
	if r.consecutiveFailures >= r.cfg.Circuit.FailureThreshold {
		r.circuitOpenUntil = time.Now().Add(r.cfg.Circuit.OpenFor)
		r.consecutiveFailures = 0
		r.telemetry.mu.Lock()
		r.telemetry.v.CircuitOpened++
		r.telemetry.mu.Unlock()
	}
}

func (r *ProcessRuntime) noteSuccess() {
	r.mu.Lock()
	r.consecutiveFailures = 0
	r.mu.Unlock()
}

func (r *ProcessRuntime) recordSuccess(operation string, started time.Time) {
	latency := time.Since(started)
	r.telemetry.mu.Lock()
	defer r.telemetry.mu.Unlock()
	r.telemetry.v.Calls++
	r.telemetry.v.ByOperation[operation]++
	r.telemetry.v.LatencyTotal += latency
	if latency > r.telemetry.v.LatencyMax {
		r.telemetry.v.LatencyMax = latency
	}
}

func (r *ProcessRuntime) recordFailure(
	operation string, started time.Time, code ErrorCode, detail string, retry bool, cause error,
) error {
	latency := time.Since(started)
	r.telemetry.mu.Lock()
	r.telemetry.v.Calls++
	r.telemetry.v.Failures++
	r.telemetry.v.ByOperation[operation]++
	r.telemetry.v.ByError[code]++
	r.telemetry.v.LatencyTotal += latency
	if latency > r.telemetry.v.LatencyMax {
		r.telemetry.v.LatencyMax = latency
	}
	r.telemetry.mu.Unlock()
	return failure(code, detail, retry, cause)
}

func withCallDeadline(parent context.Context, maximum time.Duration) (context.Context, context.CancelFunc) {
	if deadline, ok := parent.Deadline(); ok && time.Until(deadline) <= maximum {
		return context.WithCancel(parent)
	}
	return context.WithTimeout(parent, maximum)
}

func classifyContext(err error) ErrorCode {
	if errors.Is(err, context.DeadlineExceeded) {
		return CodeDeadlineExceeded
	}
	return CodeCancelled
}

func contextFailure(err error) error {
	code := classifyContext(err)
	return failure(code, err.Error(), false, err)
}

func classifyRPC(err error) ErrorCode {
	switch status.Code(err) {
	case codes.Canceled:
		return CodeCancelled
	case codes.DeadlineExceeded:
		return CodeDeadlineExceeded
	case codes.ResourceExhausted:
		if strings.Contains(strings.ToLower(status.Convert(err).Message()), "larger than max") {
			return CodePayloadTooLarge
		}
		return CodeResourceExhausted
	case codes.Unavailable:
		return CodeUnavailable
	case codes.Internal, codes.DataLoss, codes.Unknown:
		return CodeMalformedReply
	default:
		return CodeInternal
	}
}

func retryable(code ErrorCode) bool {
	return code == CodeUnavailable || code == CodeResourceExhausted || code == CodeCircuitOpen
}

func randomID(prefix string) (string, error) {
	var raw [12]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return prefix + ":" + hex.EncodeToString(raw[:]), nil
}
