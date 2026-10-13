// Package bridge implements calls between independently loaded namespace modules.
// Stable ports and context stay in core; namespace DTOs may be versioned locally.
package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
)

// Invoke resolves and pins the current provider on every call. Arguments and
// result pointers provide a typed facade; compatible versioned DTOs cross the
// boundary through JSON when their Go package identities differ.
func Invoke(ctx context.Context, k api.Kernel, namespace, method string, args []any, outputs ...any) (err error) {
	p, err := k.Resolve("service/" + namespace)
	if err != nil {
		return err
	}
	provider, ok := p.(api.ServiceProvider)
	if !ok {
		return errs.New(errs.CodeUnavailable, "namespace does not expose a service bridge")
	}
	var service any
	var release func()
	if scoped, ok := provider.(api.ScopedServiceProvider); ok {
		service, ctx, release, err = scoped.AcquireContext(ctx)
	} else {
		service, release, err = provider.Acquire(ctx)
	}
	if err != nil {
		return err
	}
	defer release()
	call := reflect.ValueOf(service).MethodByName(method)
	if !call.IsValid() {
		return errs.New(errs.CodeUnavailable, "namespace method unavailable: "+namespace+"/"+method)
	}
	if call.Type().NumIn() != len(args) {
		return errs.InvalidArgument("bridge argument count mismatch")
	}
	values := make([]reflect.Value, len(args))
	for i, arg := range args {
		if _, ok := arg.(context.Context); ok {
			arg = ctx
		}
		value, err := convert(arg, call.Type().In(i))
		if err != nil {
			return err
		}
		values[i] = value
	}
	// Panics in a plugin's service are returned to its caller, never promoted to
	// lifecycle success or allowed to corrupt the host's registration state.
	defer func() {
		if fault := recover(); fault != nil {
			err = errs.New(errs.CodePlugin, fmt.Sprintf("namespace %s method %s panicked: %v", namespace, method, fault))
		}
	}()
	results := call.Call(values)
	errorType := reflect.TypeOf((*error)(nil)).Elem()
	for i, result := range results {
		if result.Type().Implements(errorType) {
			if !result.IsNil() {
				return result.Interface().(error)
			}
			continue
		}
		if i >= len(outputs) {
			return errs.InvalidArgument("bridge result count mismatch")
		}
		target := reflect.ValueOf(outputs[i])
		if target.Kind() != reflect.Pointer || target.IsNil() {
			return errs.InvalidArgument("bridge output must be a pointer")
		}
		value, err := convert(result.Interface(), target.Elem().Type())
		if err != nil {
			return err
		}
		target.Elem().Set(value)
	}
	return nil
}

func convert(value any, target reflect.Type) (reflect.Value, error) {
	if value == nil {
		return reflect.Zero(target), nil
	}
	source := reflect.ValueOf(value)
	if source.Type().AssignableTo(target) {
		return source, nil
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return reflect.Value{}, errs.Wrap(errs.CodePlugin, err, "encode namespace DTO")
	}
	destination := reflect.New(target)
	if err := json.Unmarshal(raw, destination.Interface()); err != nil {
		return reflect.Value{}, errs.Wrap(errs.CodePlugin, err, "decode namespace DTO")
	}
	return destination.Elem(), nil
}
