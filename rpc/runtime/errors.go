package runtime

import (
	"errors"
	"fmt"
)

// ErrorCode is the stable platform-side classification for failures that happen
// before an adapter can return an Adapter RPC ResponseMeta.
type ErrorCode string

const (
	CodeCancelled         ErrorCode = "cancelled"
	CodeDeadlineExceeded  ErrorCode = "deadline_exceeded"
	CodePayloadTooLarge   ErrorCode = "payload_too_large"
	CodeResourceExhausted ErrorCode = "resource_exhausted"
	CodeUnavailable       ErrorCode = "unavailable"
	CodeMalformedReply    ErrorCode = "malformed_reply"
	CodeStaleEpoch        ErrorCode = "stale_epoch"
	CodeCircuitOpen       ErrorCode = "circuit_open"
	CodeInternal          ErrorCode = "internal"
)

// Error is deliberately free of game payloads so it is safe to record in
// platform telemetry.
type Error struct {
	Code      ErrorCode
	Detail    string
	Retryable bool
	Cause     error
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Code)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Detail)
}

func (e *Error) Unwrap() error { return e.Cause }

func IsCode(err error, code ErrorCode) bool {
	var runtimeErr *Error
	return errors.As(err, &runtimeErr) && runtimeErr.Code == code
}

func failure(code ErrorCode, detail string, retryable bool, cause error) error {
	return &Error{Code: code, Detail: detail, Retryable: retryable, Cause: cause}
}
