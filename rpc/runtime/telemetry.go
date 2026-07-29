package runtime

import (
	"sync"
	"time"
)

type Telemetry struct {
	AdapterPackage string
	RuntimeID      string
	AdapterEpoch   uint64
	ProcessStarts  uint64
	ProcessCrashes uint64
	Restarts       uint64
	Calls          uint64
	Failures       uint64
	QueueRejected  uint64
	CircuitOpened  uint64
	InFlight       int
	QueueDepth     int
	LatencyTotal   time.Duration
	LatencyMax     time.Duration
	ByOperation    map[string]uint64
	ByError        map[ErrorCode]uint64
}

type telemetryState struct {
	mu sync.Mutex
	v  Telemetry
}

func newTelemetry(adapterPackage, runtimeID string) *telemetryState {
	return &telemetryState{v: Telemetry{
		AdapterPackage: adapterPackage,
		RuntimeID:      runtimeID,
		ByOperation:    make(map[string]uint64),
		ByError:        make(map[ErrorCode]uint64),
	}}
}

func (s *telemetryState) snapshot() Telemetry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.v
	out.ByOperation = cloneMap(s.v.ByOperation)
	out.ByError = cloneMap(s.v.ByError)
	return out
}

func cloneMap[K comparable, V any](in map[K]V) map[K]V {
	out := make(map[K]V, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}
