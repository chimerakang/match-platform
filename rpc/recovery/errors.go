package recovery

import (
	"errors"
	"fmt"

	adapterv1 "github.com/chimerakang/hersir/rpc/gen/go/adapter/v1"
)

type ErrorCode string

const (
	CodeCorrupt           ErrorCode = "corrupt_store"
	CodeIncompatible      ErrorCode = "incompatible_version"
	CodeStaleEpoch        ErrorCode = "stale_epoch"
	CodeOutOfOrder        ErrorCode = "out_of_order"
	CodeDuplicateMismatch ErrorCode = "duplicate_request_mismatch"
	CodeUnknownOutcome    ErrorCode = "unknown_outcome"
	CodeStorage           ErrorCode = "storage_failure"
	CodeAdapter           ErrorCode = "adapter_failure"
	CodeHashMismatch      ErrorCode = "state_hash_mismatch"
)

type Error struct {
	Code   ErrorCode
	Detail string
	Cause  error
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Code)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Detail)
}

func (e *Error) Unwrap() error { return e.Cause }

func IsCode(err error, code ErrorCode) bool {
	var recoveryErr *Error
	return errors.As(err, &recoveryErr) && recoveryErr.Code == code
}

func fail(code ErrorCode, detail string, cause error) error {
	return &Error{Code: code, Detail: detail, Cause: cause}
}

// StatusCode maps persistence failures back to the stable Adapter RPC v1
// status vocabulary without exposing filesystem details or opaque payloads.
func StatusCode(err error) adapterv1.StatusCode {
	var recoveryErr *Error
	if !errors.As(err, &recoveryErr) {
		return adapterv1.StatusCode_STATUS_INTERNAL
	}
	switch recoveryErr.Code {
	case CodeIncompatible:
		return adapterv1.StatusCode_STATUS_UNSUPPORTED_PROTOCOL
	case CodeStaleEpoch:
		return adapterv1.StatusCode_STATUS_STALE_EPOCH
	case CodeOutOfOrder, CodeDuplicateMismatch:
		return adapterv1.StatusCode_STATUS_OUT_OF_ORDER
	case CodeUnknownOutcome:
		return adapterv1.StatusCode_STATUS_UNKNOWN_OUTCOME
	case CodeStorage, CodeAdapter:
		return adapterv1.StatusCode_STATUS_UNAVAILABLE
	default:
		return adapterv1.StatusCode_STATUS_INTERNAL
	}
}
