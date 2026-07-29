package runtime

import (
	"context"

	adapterv1 "github.com/chimerakang/hersir/rpc/gen/go/adapter/v1"
)

// AdapterRuntime is the supervised process counterpart to the trusted
// InProcessRuntime seam. The generated client methods are the language-neutral
// operation surface; lifecycle and telemetry remain platform-owned.
type AdapterRuntime interface {
	adapterv1.AdapterServiceClient
	Start(context.Context) error
	AwaitReady(context.Context) error
	Drain(context.Context) error
	Kill() error
	Close() error
	RuntimeIdentity() (runtimeID, adapterInstanceID string, adapterEpoch uint64)
	Telemetry() Telemetry
}

var _ AdapterRuntime = (*ProcessRuntime)(nil)
