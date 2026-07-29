package runtime

import (
	"context"

	adapterv1 "github.com/chimerakang/hersir/rpc/gen/go/adapter/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

func invokeTyped[Request proto.Message, Response proto.Message](
	r *ProcessRuntime,
	ctx context.Context,
	operation string,
	request Request,
	response Response,
	call func(adapterv1.AdapterServiceClient, context.Context, Request, ...grpc.CallOption) (Response, error),
	options ...grpc.CallOption,
) (Response, error) {
	err := r.invoke(ctx, operation, request, response,
		func(callCtx context.Context, client adapterv1.AdapterServiceClient) error {
			value, callErr := call(client, callCtx, request, options...)
			if callErr == nil {
				proto.Merge(response, value)
			}
			return callErr
		})
	if err != nil {
		var zero Response
		return zero, err
	}
	return response, nil
}

func (r *ProcessRuntime) Negotiate(ctx context.Context, in *adapterv1.NegotiateRequest, opts ...grpc.CallOption) (*adapterv1.NegotiateResponse, error) {
	return invokeTyped(r, ctx, "Negotiate", in, new(adapterv1.NegotiateResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.NegotiateRequest, opts ...grpc.CallOption) (*adapterv1.NegotiateResponse, error) {
			return c.Negotiate(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) GetDescriptor(ctx context.Context, in *adapterv1.GetDescriptorRequest, opts ...grpc.CallOption) (*adapterv1.GetDescriptorResponse, error) {
	return invokeTyped(r, ctx, "GetDescriptor", in, new(adapterv1.GetDescriptorResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.GetDescriptorRequest, opts ...grpc.CallOption) (*adapterv1.GetDescriptorResponse, error) {
			return c.GetDescriptor(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) GetSlotDescriptors(ctx context.Context, in *adapterv1.GetSlotDescriptorsRequest, opts ...grpc.CallOption) (*adapterv1.GetSlotDescriptorsResponse, error) {
	return invokeTyped(r, ctx, "GetSlotDescriptors", in, new(adapterv1.GetSlotDescriptorsResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.GetSlotDescriptorsRequest, opts ...grpc.CallOption) (*adapterv1.GetSlotDescriptorsResponse, error) {
			return c.GetSlotDescriptors(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) ValidateMatchConfig(ctx context.Context, in *adapterv1.ValidateMatchConfigRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
	return invokeTyped(r, ctx, "ValidateMatchConfig", in, new(adapterv1.StatusResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.ValidateMatchConfigRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
			return c.ValidateMatchConfig(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) CreateMatch(ctx context.Context, in *adapterv1.CreateMatchRequest, opts ...grpc.CallOption) (*adapterv1.MatchResponse, error) {
	return invokeTyped(r, ctx, "CreateMatch", in, new(adapterv1.MatchResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.CreateMatchRequest, opts ...grpc.CallOption) (*adapterv1.MatchResponse, error) {
			return c.CreateMatch(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) RecoverMatch(ctx context.Context, in *adapterv1.RecoverMatchRequest, opts ...grpc.CallOption) (*adapterv1.MatchResponse, error) {
	return invokeTyped(r, ctx, "RecoverMatch", in, new(adapterv1.MatchResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.RecoverMatchRequest, opts ...grpc.CallOption) (*adapterv1.MatchResponse, error) {
			return c.RecoverMatch(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) ValidateJoin(ctx context.Context, in *adapterv1.ValidateJoinRequest, opts ...grpc.CallOption) (*adapterv1.ValidateJoinResponse, error) {
	return invokeTyped(r, ctx, "ValidateJoin", in, new(adapterv1.ValidateJoinResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.ValidateJoinRequest, opts ...grpc.CallOption) (*adapterv1.ValidateJoinResponse, error) {
			return c.ValidateJoin(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) ValidateCommand(ctx context.Context, in *adapterv1.ValidateCommandRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
	return invokeTyped(r, ctx, "ValidateCommand", in, new(adapterv1.StatusResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.ValidateCommandRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
			return c.ValidateCommand(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) ApplyCommand(ctx context.Context, in *adapterv1.ApplyCommandRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
	return invokeTyped(r, ctx, "ApplyCommand", in, new(adapterv1.StatusResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.ApplyCommandRequest, opts ...grpc.CallOption) (*adapterv1.StatusResponse, error) {
			return c.ApplyCommand(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) Advance(ctx context.Context, in *adapterv1.AdvanceRequest, opts ...grpc.CallOption) (*adapterv1.AdvanceResponse, error) {
	return invokeTyped(r, ctx, "Advance", in, new(adapterv1.AdvanceResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.AdvanceRequest, opts ...grpc.CallOption) (*adapterv1.AdvanceResponse, error) {
			return c.Advance(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) GetTerminalResult(ctx context.Context, in *adapterv1.GetTerminalResultRequest, opts ...grpc.CallOption) (*adapterv1.OpaqueResponse, error) {
	return invokeTyped(r, ctx, "GetTerminalResult", in, new(adapterv1.OpaqueResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.GetTerminalResultRequest, opts ...grpc.CallOption) (*adapterv1.OpaqueResponse, error) {
			return c.GetTerminalResult(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) GetStateHash(ctx context.Context, in *adapterv1.GetStateHashRequest, opts ...grpc.CallOption) (*adapterv1.StateHashResponse, error) {
	return invokeTyped(r, ctx, "GetStateHash", in, new(adapterv1.StateHashResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.GetStateHashRequest, opts ...grpc.CallOption) (*adapterv1.StateHashResponse, error) {
			return c.GetStateHash(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) ExportReplay(ctx context.Context, in *adapterv1.ExportReplayRequest, opts ...grpc.CallOption) (*adapterv1.OpaqueResponse, error) {
	return invokeTyped(r, ctx, "ExportReplay", in, new(adapterv1.OpaqueResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.ExportReplayRequest, opts ...grpc.CallOption) (*adapterv1.OpaqueResponse, error) {
			return c.ExportReplay(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) BuildCheckpoint(ctx context.Context, in *adapterv1.BuildCheckpointRequest, opts ...grpc.CallOption) (*adapterv1.CheckpointResponse, error) {
	return invokeTyped(r, ctx, "BuildCheckpoint", in, new(adapterv1.CheckpointResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.BuildCheckpointRequest, opts ...grpc.CallOption) (*adapterv1.CheckpointResponse, error) {
			return c.BuildCheckpoint(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) BuildDelta(ctx context.Context, in *adapterv1.BuildDeltaRequest, opts ...grpc.CallOption) (*adapterv1.DeltaResponse, error) {
	return invokeTyped(r, ctx, "BuildDelta", in, new(adapterv1.DeltaResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.BuildDeltaRequest, opts ...grpc.CallOption) (*adapterv1.DeltaResponse, error) {
			return c.BuildDelta(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) DrainEvents(ctx context.Context, in *adapterv1.DrainEventsRequest, opts ...grpc.CallOption) (*adapterv1.DrainEventsResponse, error) {
	return invokeTyped(r, ctx, "DrainEvents", in, new(adapterv1.DrainEventsResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.DrainEventsRequest, opts ...grpc.CallOption) (*adapterv1.DrainEventsResponse, error) {
			return c.DrainEvents(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) GetMetrics(ctx context.Context, in *adapterv1.GetMetricsRequest, opts ...grpc.CallOption) (*adapterv1.MetricsResponse, error) {
	return invokeTyped(r, ctx, "GetMetrics", in, new(adapterv1.MetricsResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.GetMetricsRequest, opts ...grpc.CallOption) (*adapterv1.MetricsResponse, error) {
			return c.GetMetrics(ctx, in, opts...)
		}, opts...)
}

func (r *ProcessRuntime) Health(ctx context.Context, in *adapterv1.HealthRequest, opts ...grpc.CallOption) (*adapterv1.HealthResponse, error) {
	return invokeTyped(r, ctx, "Health", in, new(adapterv1.HealthResponse),
		func(c adapterv1.AdapterServiceClient, ctx context.Context, in *adapterv1.HealthRequest, opts ...grpc.CallOption) (*adapterv1.HealthResponse, error) {
			return c.Health(ctx, in, opts...)
		}, opts...)
}
