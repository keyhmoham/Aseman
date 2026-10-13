// Package errs provides typed, code-carrying errors used across tradera.
// Every error produced by the kernel, plugins, actions and adapters should be
// created through this package so that the CLI/API can render stable codes.
package errs

import (
	"errors"
	"fmt"
)

// Code is a stable machine readable error code.
type Code string

const (
	CodeNotFound        Code = "NOT_FOUND"
	CodeAlreadyExists   Code = "ALREADY_EXISTS"
	CodeInvalidArgument Code = "INVALID_ARGUMENT"
	CodeUnauthenticated Code = "UNAUTHENTICATED"
	CodePermission      Code = "PERMISSION_DENIED"
	CodeConflict        Code = "CONFLICT"
	CodeUnavailable     Code = "UNAVAILABLE"
	CodePlugin          Code = "PLUGIN_ERROR"
	CodeFederation      Code = "FEDERATION_ERROR"
	CodeFinance         Code = "FINANCE_ERROR"
	CodeVMM             Code = "VMM_ERROR"
	CodeInternal        Code = "INTERNAL"
	CodeBudgetExhausted Code = "BUDGET_EXHAUSTED"
)

// Error is a tradera error carrying a stable code and optional metadata.
type Error struct {
	Code    Code
	Message string
	Cause   error
	Meta    map[string]any
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %s: %v", e.Code, e.Message, e.Cause)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func (e *Error) Unwrap() error { return e.Cause }

// New builds a new coded error.
func New(code Code, msg string) *Error {
	return &Error{Code: code, Message: msg}
}

// Wrap builds a coded error wrapping a cause.
func Wrap(code Code, cause error, msg string) *Error {
	return &Error{Code: code, Message: msg, Cause: cause}
}

// WithMeta attaches structured metadata to the error.
func WithMeta(e *Error, key string, value any) *Error {
	if e.Meta == nil {
		e.Meta = map[string]any{}
	}
	e.Meta[key] = value
	return e
}

// NotFound creates a NOT_FOUND error.
func NotFound(msg string) *Error { return New(CodeNotFound, msg) }

// InvalidArgument creates an INVALID_ARGUMENT error.
func InvalidArgument(msg string) *Error { return New(CodeInvalidArgument, msg) }

// AlreadyExists creates an ALREADY_EXISTS error.
func AlreadyExists(msg string) *Error { return New(CodeAlreadyExists, msg) }

// Conflict creates a CONFLICT error.
func Conflict(msg string) *Error { return New(CodeConflict, msg) }

// Permission creates a PERMISSION_DENIED error.
func Permission(msg string) *Error { return New(CodePermission, msg) }

// Unauthenticated creates an UNAUTHENTICATED error.
func Unauthenticated(msg string) *Error { return New(CodeUnauthenticated, msg) }

// CodeOf returns the Code of err, falling back to CodeInternal.
func CodeOf(err error) Code {
	if err == nil {
		return ""
	}
	var e *Error
	if errors.As(err, &e) {
		if e.Code == "" {
			return CodeInternal
		}
		return e.Code
	}
	return CodeInternal
}
