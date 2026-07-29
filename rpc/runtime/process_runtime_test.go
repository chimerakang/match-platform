package runtime

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	adapterv1 "github.com/chimerakang/match-platform/rpc/gen/go/adapter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

type helperAdapter struct {
	adapterv1.UnimplementedAdapterServiceServer
	instanceID  string
	epoch       uint64
	healthOnce  bool
	healthCalls atomic.Uint64
}

func (a *helperAdapter) meta(requestID uint64) *adapterv1.ResponseMeta {
	return &adapterv1.ResponseMeta{
		Code:              adapterv1.StatusCode_STATUS_OK,
		RequestId:         requestID,
		AdapterInstanceId: a.instanceID,
		AdapterEpoch:      a.epoch,
	}
}

func (a *helperAdapter) Health(ctx context.Context, in *adapterv1.HealthRequest) (*adapterv1.HealthResponse, error) {
	if a.healthOnce && a.healthCalls.Add(1) > 1 {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return &adapterv1.HealthResponse{
		Meta:   a.meta(in.GetRequestId()),
		Status: adapterv1.ServingStatus_SERVING,
	}, nil
}

func (a *helperAdapter) Advance(ctx context.Context, in *adapterv1.AdvanceRequest) (*adapterv1.AdvanceResponse, error) {
	if in.GetTicks() == 99 {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
	return &adapterv1.AdvanceResponse{
		Meta: a.meta(in.GetContext().GetRequestId()),
		Tick: in.GetContext().GetExpectedTick() + uint64(in.GetTicks()),
	}, nil
}

func (a *helperAdapter) GetDescriptor(_ context.Context, _ *adapterv1.GetDescriptorRequest) (*adapterv1.GetDescriptorResponse, error) {
	// Deliberately malformed: every v1 response must carry ResponseMeta.
	return &adapterv1.GetDescriptorResponse{}, nil
}

func (a *helperAdapter) ApplyCommand(_ context.Context, in *adapterv1.ApplyCommandRequest) (*adapterv1.StatusResponse, error) {
	return &adapterv1.StatusResponse{Meta: a.meta(in.GetContext().GetRequestId())}, nil
}

func (a *helperAdapter) ExportReplay(_ context.Context, in *adapterv1.ExportReplayRequest) (*adapterv1.OpaqueResponse, error) {
	return &adapterv1.OpaqueResponse{
		Meta:    a.meta(in.GetContext().GetRequestId()),
		Present: true,
		Payload: &adapterv1.OpaquePayload{CodecId: "bytes", Value: make([]byte, 64<<10)},
	}, nil
}

func TestAdapterProcessHelper(t *testing.T) {
	if os.Getenv("HERSIR_RUNTIME_TEST_HELPER") != "1" {
		return
	}
	if os.Getenv("HERSIR_RUNTIME_TEST_AMBIENT_SECRET") != "" {
		t.Fatal("adapter inherited an ambient host secret")
	}
	epoch, err := strconv.ParseUint(os.Getenv("HERSIR_ADAPTER_EPOCH"), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", os.Getenv("HERSIR_ADAPTER_RPC_ENDPOINT"))
	if err != nil {
		t.Fatal(err)
	}
	var serverOptions []grpc.ServerOption
	if certPath := os.Getenv("HERSIR_RUNTIME_TEST_SERVER_CERT"); certPath != "" {
		if os.Getenv("HERSIR_PLATFORM_WORKLOAD_IDENTITY") == "" {
			t.Fatal("secure adapter did not receive platform workload identity")
		}
		certificate, loadErr := tls.LoadX509KeyPair(
			certPath, os.Getenv("HERSIR_RUNTIME_TEST_SERVER_KEY"))
		if loadErr != nil {
			t.Fatal(loadErr)
		}
		caPEM, readErr := os.ReadFile(os.Getenv("HERSIR_RUNTIME_TEST_CA"))
		if readErr != nil {
			t.Fatal(readErr)
		}
		clientCAs := x509.NewCertPool()
		if !clientCAs.AppendCertsFromPEM(caPEM) {
			t.Fatal("could not load test client CA")
		}
		serverOptions = append(serverOptions, grpc.Creds(credentials.NewTLS(&tls.Config{
			Certificates: []tls.Certificate{certificate},
			ClientAuth:   tls.RequireAndVerifyClientCert,
			ClientCAs:    clientCAs,
			MinVersion:   tls.VersionTLS13,
		})))
	}
	server := grpc.NewServer(serverOptions...)
	adapterv1.RegisterAdapterServiceServer(server, &helperAdapter{
		instanceID: os.Getenv("HERSIR_ADAPTER_INSTANCE_ID"),
		epoch:      epoch,
		healthOnce: os.Getenv("HERSIR_RUNTIME_TEST_HEALTH_ONCE") == "1",
	})
	if err := server.Serve(listener); err != nil {
		t.Fatal(err)
	}
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

func testConfig(t *testing.T, packageID string) Config {
	t.Helper()
	return Config{
		AdapterPackage:     packageID,
		Endpoint:           freeEndpoint(t),
		AllowInsecureTests: true,
		Process: ProcessSpec{
			Command: os.Args[0],
			Args:    []string{"-test.run=^TestAdapterProcessHelper$"},
			Env:     []string{"HERSIR_RUNTIME_TEST_HELPER=1"},
		},
		MaxConcurrent:  2,
		QueueCapacity:  2,
		CallTimeout:    time.Second,
		ReadyTimeout:   3 * time.Second,
		HealthInterval: 20 * time.Millisecond,
		Restart: RestartPolicy{
			MaxRestarts: 2,
			Backoff:     20 * time.Millisecond,
		},
		Circuit: CircuitBreakerPolicy{
			FailureThreshold: 3,
			OpenFor:          200 * time.Millisecond,
		},
	}
}

func startTestRuntime(t *testing.T, cfg Config) *ProcessRuntime {
	t.Helper()
	runtime, err := NewProcessRuntime(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if err := runtime.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtime.Close() })
	return runtime
}

func healthRequest() *adapterv1.HealthRequest {
	return &adapterv1.HealthRequest{
		Protocol:       &adapterv1.ProtocolVersion{Major: 1, Minor: 0},
		RequestId:      42,
		DeadlineUnixMs: uint64(time.Now().Add(time.Second).UnixMilli()),
	}
}

func matchContext(runtime *ProcessRuntime, requestID uint64) *adapterv1.RequestContext {
	_, instanceID, epoch := runtime.RuntimeIdentity()
	return &adapterv1.RequestContext{
		Protocol:          &adapterv1.ProtocolVersion{Major: 1, Minor: 0},
		MatchId:           "match-fixture",
		AdapterInstanceId: instanceID,
		AdapterEpoch:      epoch,
		RequestId:         requestID,
		DeadlineUnixMs:    uint64(time.Now().Add(time.Second).UnixMilli()),
	}
}

func TestProcessRuntimeLifecycleAndRestartEpoch(t *testing.T) {
	runtime := startTestRuntime(t, testConfig(t, "counter"))
	if _, err := runtime.Health(context.Background(), healthRequest()); err != nil {
		t.Fatal(err)
	}
	_, firstInstance, firstEpoch := runtime.RuntimeIdentity()
	if err := runtime.Kill(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	for {
		if err := runtime.AwaitReady(ctx); err != nil {
			t.Fatal(err)
		}
		_, instance, epoch := runtime.RuntimeIdentity()
		if epoch > firstEpoch {
			if instance == firstInstance {
				t.Fatal("restart reused the prior adapter instance id")
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	telemetry := runtime.Telemetry()
	if telemetry.Restarts != 1 || telemetry.ProcessStarts != 2 || telemetry.AdapterEpoch != firstEpoch+1 {
		t.Fatalf("unexpected restart telemetry: %+v", telemetry)
	}
}

func TestProcessRuntimeRestartsAnUnresponsiveProcess(t *testing.T) {
	cfg := testConfig(t, "liveness")
	cfg.Process.Env = append(cfg.Process.Env, "HERSIR_RUNTIME_TEST_HEALTH_ONCE=1")
	cfg.LivenessInterval = 30 * time.Millisecond
	cfg.LivenessFailures = 2
	runtime := startTestRuntime(t, cfg)
	_, _, firstEpoch := runtime.RuntimeIdentity()

	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		_, _, epoch := runtime.RuntimeIdentity()
		if epoch > firstEpoch {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			err := runtime.AwaitReady(ctx)
			cancel()
			if err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("liveness failure did not restart the adapter process")
}

func TestProcessRuntimeGracefulDrain(t *testing.T) {
	runtime := startTestRuntime(t, testConfig(t, "drain"))
	finished := make(chan error, 1)
	go func() {
		_, err := runtime.Advance(context.Background(), &adapterv1.AdvanceRequest{
			Context: matchContext(runtime, 1),
			Ticks:   99,
		})
		finished <- err
	}()
	time.Sleep(50 * time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := runtime.Drain(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-finished; err != nil {
		t.Fatalf("accepted call was interrupted during drain: %v", err)
	}
	if _, err := runtime.Health(context.Background(), healthRequest()); !IsCode(err, CodeUnavailable) {
		t.Fatalf("post-drain call = %v, want unavailable", err)
	}
}

func TestProcessRuntimeDeterministicFailureClassification(t *testing.T) {
	cfg := testConfig(t, "faults")
	cfg.MaxRequestBytes = 512
	cfg.MaxResponseBytes = 1024
	runtime := startTestRuntime(t, cfg)

	cancelled, cancelNow := context.WithCancel(context.Background())
	cancelNow()
	_, err := runtime.Health(cancelled, healthRequest())
	if !IsCode(err, CodeCancelled) {
		t.Fatalf("cancelled call = %v, want cancelled", err)
	}
	expired := healthRequest()
	expired.DeadlineUnixMs = uint64(time.Now().Add(-time.Second).UnixMilli())
	_, err = runtime.Health(context.Background(), expired)
	if !IsCode(err, CodeDeadlineExceeded) {
		t.Fatalf("expired absolute deadline = %v, want deadline_exceeded", err)
	}

	short, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	_, err = runtime.Advance(short, &adapterv1.AdvanceRequest{
		Context: matchContext(runtime, 1),
		Ticks:   99,
	})
	if !IsCode(err, CodeDeadlineExceeded) {
		t.Fatalf("slow reply = %v, want deadline_exceeded", err)
	}

	_, err = runtime.GetDescriptor(context.Background(), &adapterv1.GetDescriptorRequest{
		Protocol:       &adapterv1.ProtocolVersion{Major: 1},
		RequestId:      2,
		DeadlineUnixMs: uint64(time.Now().Add(time.Second).UnixMilli()),
	})
	if !IsCode(err, CodeMalformedReply) {
		t.Fatalf("missing response metadata = %v, want malformed_reply", err)
	}

	_, err = runtime.ApplyCommand(context.Background(), &adapterv1.ApplyCommandRequest{
		Context: matchContext(runtime, 3),
		Command: &adapterv1.OpaquePayload{CodecId: "bytes", Value: make([]byte, 2048)},
	})
	if !IsCode(err, CodePayloadTooLarge) {
		t.Fatalf("oversized request = %v, want payload_too_large", err)
	}

	_, err = runtime.ExportReplay(context.Background(), &adapterv1.ExportReplayRequest{
		Context: matchContext(runtime, 4),
	})
	if !IsCode(err, CodePayloadTooLarge) {
		t.Fatalf("oversized response = %v, want payload_too_large", err)
	}

}

func TestProcessRuntimeUnavailableBeforeStart(t *testing.T) {
	runtime, err := NewProcessRuntime(testConfig(t, "not-started"))
	if err != nil {
		t.Fatal(err)
	}
	_, err = runtime.Health(context.Background(), healthRequest())
	if !IsCode(err, CodeUnavailable) {
		t.Fatalf("call before readiness = %v, want unavailable", err)
	}
}

func TestProcessRuntimeQueueIsolationAndCircuitBreaker(t *testing.T) {
	cfgA := testConfig(t, "adapter-a")
	cfgA.MaxConcurrent = 1
	cfgA.QueueCapacity = 1
	cfgA.Circuit.FailureThreshold = 1
	runtimeA := startTestRuntime(t, cfgA)
	runtimeB := startTestRuntime(t, testConfig(t, "adapter-b"))

	var started sync.WaitGroup
	var finished sync.WaitGroup
	started.Add(2)
	finished.Add(2)
	block := func(id uint64) {
		defer finished.Done()
		started.Done()
		_, _ = runtimeA.Advance(context.Background(), &adapterv1.AdvanceRequest{
			Context: matchContext(runtimeA, id),
			Ticks:   99,
		})
	}
	go block(1)
	time.Sleep(30 * time.Millisecond)
	go block(2)
	started.Wait()
	time.Sleep(30 * time.Millisecond)

	_, err := runtimeA.Advance(context.Background(), &adapterv1.AdvanceRequest{
		Context: matchContext(runtimeA, 3),
		Ticks:   1,
	})
	if !IsCode(err, CodeResourceExhausted) {
		t.Fatalf("saturated adapter = %v, want resource_exhausted", err)
	}
	if _, err := runtimeB.Health(context.Background(), healthRequest()); err != nil {
		t.Fatalf("adapter B was affected by adapter A saturation: %v", err)
	}
	finished.Wait()

	_, err = runtimeA.GetDescriptor(context.Background(), &adapterv1.GetDescriptorRequest{
		Protocol:       &adapterv1.ProtocolVersion{Major: 1},
		RequestId:      4,
		DeadlineUnixMs: uint64(time.Now().Add(time.Second).UnixMilli()),
	})
	if !IsCode(err, CodeMalformedReply) {
		t.Fatalf("malformed reply = %v", err)
	}
	_, err = runtimeA.Health(context.Background(), healthRequest())
	if !IsCode(err, CodeCircuitOpen) {
		t.Fatalf("call after breaker trip = %v, want circuit_open", err)
	}
	if _, err := runtimeB.Health(context.Background(), healthRequest()); err != nil {
		t.Fatalf("adapter B was affected by adapter A breaker: %v", err)
	}
}

func TestProcessRuntimeRejectsStaleResponseAfterEpochChange(t *testing.T) {
	runtime := startTestRuntime(t, testConfig(t, "stale"))
	result := make(chan error, 1)
	go func() {
		_, err := runtime.Advance(context.Background(), &adapterv1.AdvanceRequest{
			Context: matchContext(runtime, 1),
			Ticks:   99,
		})
		result <- err
	}()
	time.Sleep(50 * time.Millisecond)
	runtime.mu.Lock()
	runtime.epoch++
	runtime.telemetry.mu.Lock()
	runtime.telemetry.v.AdapterEpoch = runtime.epoch
	runtime.telemetry.mu.Unlock()
	runtime.mu.Unlock()
	if err := <-result; !IsCode(err, CodeStaleEpoch) {
		t.Fatalf("prior-epoch response = %v, want stale_epoch", err)
	}
}

func TestProcessRuntimeEnforcesLocalIdentityBoundary(t *testing.T) {
	cfg := testConfig(t, "security")
	cfg.Endpoint = "0.0.0.0:50051"
	if _, err := NewProcessRuntime(cfg); err == nil {
		t.Fatal("public adapter endpoint was accepted")
	}
	cfg.Endpoint = freeEndpoint(t)
	cfg.AllowInsecureTests = false
	if _, err := NewProcessRuntime(cfg); err == nil {
		t.Fatal("runtime without mTLS credentials was accepted")
	}
	cfg.Credentials = credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS13})
	cfg.WorkloadIdentity = "spiffe://hersir.test/platform"
	cfg.Process.InheritEnvironment = true
	if _, err := NewProcessRuntime(cfg); err == nil {
		t.Fatal("production runtime accepted ambient environment inheritance")
	}
	cfg.Process.InheritEnvironment = false
	if _, err := NewProcessRuntime(cfg); err == nil {
		t.Fatal("production runtime accepted a raw unsandboxed adapter command")
	}
}

func TestProcessRuntimeScrubsAmbientEnvironment(t *testing.T) {
	t.Setenv("HERSIR_RUNTIME_TEST_AMBIENT_SECRET", "must-not-cross-boundary")
	runtime := startTestRuntime(t, testConfig(t, "clean-environment"))
	if _, err := runtime.Health(context.Background(), healthRequest()); err != nil {
		t.Fatal(err)
	}
}

func TestProcessRuntimeMutualTLSWorkloadIdentity(t *testing.T) {
	clientCredentials, helperEnvironment := mutualTLSFixture(t)
	cfg := testConfig(t, "secure-adapter")
	cfg.AllowInsecureTests = false
	cfg.Credentials = clientCredentials
	cfg.WorkloadIdentity = "spiffe://hersir.test/match-platform"
	cfg.Process.Sandboxed = true
	cfg.Process.Env = append(cfg.Process.Env, helperEnvironment...)
	runtime := startTestRuntime(t, cfg)
	if _, err := runtime.Health(context.Background(), healthRequest()); err != nil {
		t.Fatal(err)
	}
}

func mutualTLSFixture(t *testing.T) (credentials.TransportCredentials, []string) {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Match Platform runtime test CA"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCertificate, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	tempDir := t.TempDir()
	caPath := filepath.Join(tempDir, "ca.pem")
	writePEM(t, caPath, "CERTIFICATE", caDER)
	serverCert, serverKey := issueCertificate(t, tempDir, "server", 2, caCertificate, caKey,
		[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth})
	clientCert, clientKey := issueCertificate(t, tempDir, "client", 3, caCertificate, caKey,
		[]x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth})

	clientCertificate, err := tls.LoadX509KeyPair(clientCert, clientKey)
	if err != nil {
		t.Fatal(err)
	}
	rootCAs := x509.NewCertPool()
	rootCAs.AddCert(caCertificate)
	clientCredentials := credentials.NewTLS(&tls.Config{
		Certificates: []tls.Certificate{clientCertificate},
		RootCAs:      rootCAs,
		ServerName:   "adapter.hersir.test",
		MinVersion:   tls.VersionTLS13,
	})
	return clientCredentials, []string{
		"HERSIR_RUNTIME_TEST_CA=" + caPath,
		"HERSIR_RUNTIME_TEST_SERVER_CERT=" + serverCert,
		"HERSIR_RUNTIME_TEST_SERVER_KEY=" + serverKey,
	}
}

func issueCertificate(
	t *testing.T,
	tempDir, name string,
	serial int64,
	ca *x509.Certificate,
	caKey *ecdsa.PrivateKey,
	usage []x509.ExtKeyUsage,
) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: name},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  usage,
		DNSNames:     []string{"adapter.hersir.test"},
	}
	certificateDER, err := x509.CreateCertificate(
		rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPath := filepath.Join(tempDir, name+".pem")
	keyPath := filepath.Join(tempDir, name+"-key.pem")
	writePEM(t, certPath, "CERTIFICATE", certificateDER)
	writePEM(t, keyPath, "EC PRIVATE KEY", keyDER)
	return certPath, keyPath
}

func writePEM(t *testing.T, path, blockType string, bytes []byte) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := pem.Encode(file, &pem.Block{Type: blockType, Bytes: bytes}); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestProcessRuntimeLatencyBudget(t *testing.T) {
	runtime := startTestRuntime(t, testConfig(t, "latency"))
	const calls = 200
	started := time.Now()
	for index := 0; index < calls; index++ {
		request := healthRequest()
		request.RequestId = uint64(index + 1)
		if _, err := runtime.Health(context.Background(), request); err != nil {
			t.Fatal(err)
		}
	}
	average := time.Since(started) / calls
	t.Logf("ADAPTER_PROCESS_RUNTIME_BENCH calls=%d average=%s", calls, average)
	if average > 5*time.Millisecond {
		t.Fatalf("local RPC overhead %s exceeds 5ms budget", average)
	}
	telemetry := runtime.Telemetry()
	if telemetry.Calls != calls {
		t.Fatalf("telemetry calls=%d, want %d", telemetry.Calls, calls)
	}
}

func TestErrorFormattingDoesNotContainPayload(t *testing.T) {
	err := failure(CodeUnavailable, "endpoint unavailable", true, fmt.Errorf("dial failed"))
	if got := err.Error(); got != "unavailable: endpoint unavailable" {
		t.Fatalf("unexpected stable error text: %q", got)
	}
}
