package runtime

import (
	"fmt"
	"net"
	"strings"
	"time"

	"google.golang.org/grpc/credentials"
)

const (
	defaultRequestBytes  = 1 << 20
	defaultResponseBytes = 16 << 20
)

type ProcessSpec struct {
	Command string
	Args    []string
	Env     []string
	Dir     string
	// InheritEnvironment is an insecure local-development escape hatch. The
	// production default is a clean environment so ambient credentials cannot
	// cross into a third-party adapter process.
	InheritEnvironment bool
	// Sandboxed confirms Command is the trusted default-deny launcher rather
	// than the adapter artifact itself. Production construction fails closed
	// unless an operations-verified launch plan owns the process.
	Sandboxed bool
}

type RestartPolicy struct {
	MaxRestarts int
	Backoff     time.Duration
}

type CircuitBreakerPolicy struct {
	FailureThreshold int
	OpenFor          time.Duration
}

// Config is immutable after NewProcessRuntime. Each instance owns its own
// process, queue, circuit breaker and telemetry partition.
type Config struct {
	AdapterPackage string
	Endpoint       string
	Process        ProcessSpec

	Credentials        credentials.TransportCredentials
	WorkloadIdentity   string
	AllowInsecureTests bool

	MaxConcurrent    int
	QueueCapacity    int
	MaxRequestBytes  int
	MaxResponseBytes int
	CallTimeout      time.Duration
	ReadyTimeout     time.Duration
	HealthInterval   time.Duration
	LivenessInterval time.Duration
	LivenessFailures int
	DrainTimeout     time.Duration

	Restart RestartPolicy
	Circuit CircuitBreakerPolicy
}

func (c *Config) withDefaults() {
	if c.MaxConcurrent <= 0 {
		c.MaxConcurrent = 4
	}
	if c.QueueCapacity < 0 {
		c.QueueCapacity = 0
	}
	if c.MaxRequestBytes <= 0 {
		c.MaxRequestBytes = defaultRequestBytes
	}
	if c.MaxResponseBytes <= 0 {
		c.MaxResponseBytes = defaultResponseBytes
	}
	if c.CallTimeout <= 0 {
		c.CallTimeout = 5 * time.Second
	}
	if c.ReadyTimeout <= 0 {
		c.ReadyTimeout = 10 * time.Second
	}
	if c.HealthInterval <= 0 {
		c.HealthInterval = 50 * time.Millisecond
	}
	if c.LivenessInterval <= 0 {
		c.LivenessInterval = time.Second
	}
	if c.LivenessFailures <= 0 {
		c.LivenessFailures = 3
	}
	if c.DrainTimeout <= 0 {
		c.DrainTimeout = 5 * time.Second
	}
	if c.Restart.MaxRestarts <= 0 {
		c.Restart.MaxRestarts = 3
	}
	if c.Restart.Backoff <= 0 {
		c.Restart.Backoff = 100 * time.Millisecond
	}
	if c.Circuit.FailureThreshold <= 0 {
		c.Circuit.FailureThreshold = 5
	}
	if c.Circuit.OpenFor <= 0 {
		c.Circuit.OpenFor = time.Second
	}
}

func (c Config) validate() error {
	if strings.TrimSpace(c.AdapterPackage) == "" {
		return fmt.Errorf("adapter package is required")
	}
	host, _, err := net.SplitHostPort(c.Endpoint)
	if err != nil {
		return fmt.Errorf("adapter endpoint must be host:port: %w", err)
	}
	if !isLoopbackHost(host) {
		return fmt.Errorf("adapter endpoint must be loopback-only, got %q", host)
	}
	if c.Credentials == nil && !c.AllowInsecureTests {
		return fmt.Errorf("mTLS transport credentials are required")
	}
	if strings.TrimSpace(c.WorkloadIdentity) == "" && !c.AllowInsecureTests {
		return fmt.Errorf("platform workload identity is required")
	}
	if c.Process.Command == "" {
		return fmt.Errorf("adapter process command is required")
	}
	if c.Process.InheritEnvironment && !c.AllowInsecureTests {
		return fmt.Errorf("production adapter process cannot inherit the host environment")
	}
	if !c.Process.Sandboxed && !c.AllowInsecureTests {
		return fmt.Errorf("production adapter process requires a verified sandbox launcher")
	}
	if c.MaxConcurrent <= 0 || c.QueueCapacity < 0 {
		return fmt.Errorf("invalid concurrency or queue capacity")
	}
	return nil
}

func isLoopbackHost(host string) bool {
	host = strings.Trim(host, "[]")
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
