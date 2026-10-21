package database

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// dbTag is the struct tag used to name persisted fields.
const dbTag = "db"

// Decode extracts the persisted fields of a record (struct with db tags, or a
// map[string]any) into a flat map keyed by model field name. Unknown fields in
// structs are ignored; unknown keys in maps are preserved only if declared.
func Decode(m Model, v any) (map[string]any, error) {
	row := map[string]any{}
	rv := reflect.ValueOf(v)
	if rv.Kind() == reflect.Ptr {
		rv = rv.Elem()
	}
	switch rv.Kind() {
	case reflect.Map:
		if rv.Type().Key().Kind() != reflect.String {
			return nil, errs.InvalidArgument("map records must use string keys")
		}
		iter := rv.MapRange()
		for iter.Next() {
			name := iter.Key().String()
			if _, ok := m.Field(name); !ok {
				continue
			}
			row[name] = normalize(iter.Value())
		}
	case reflect.Struct:
		if err := decodeStruct(m, rv, row); err != nil {
			return nil, err
		}
	default:
		return nil, errs.InvalidArgument("record must be a struct or map")
	}
	if len(row) == 0 {
		return nil, errs.InvalidArgument("record has no persisted fields for model " + m.Name)
	}
	return row, nil
}

// decodeStruct extracts db-tagged fields, recursing into embedded structs so
// fields such as entity.Entity.ID/CreatedAt/UpdatedAt are persisted.
func decodeStruct(m Model, rv reflect.Value, row map[string]any) error {
	t := rv.Type()
	for i := 0; i < t.NumField(); i++ {
		sf := t.Field(i)
		if sf.PkgPath != "" {
			continue // unexported
		}
		fv := rv.Field(i)
		if sf.Anonymous && fv.Kind() == reflect.Struct {
			if fv.Type() == reflect.TypeOf(time.Time{}) {
				continue
			}
			if err := decodeStruct(m, fv, row); err != nil {
				return err
			}
			continue
		}
		name := sf.Tag.Get(dbTag)
		if name == "" {
			name = strings.ToLower(sf.Name)
		}
		if name == "-" {
			continue
		}
		if _, ok := m.Field(name); !ok {
			continue
		}
		row[name] = normalize(fv)
	}
	return nil
}

// Encode fills a struct (pointer) or map with values from a row.
func Encode(m Model, row map[string]any, out any) error {
	rv := reflect.ValueOf(out)
	if rv.Kind() != reflect.Ptr || rv.IsNil() {
		return errs.InvalidArgument("output must be a non-nil pointer")
	}
	rv = rv.Elem()
	switch rv.Kind() {
	case reflect.Map:
		for name, val := range row {
			rv.SetMapIndex(reflect.ValueOf(name), reflect.ValueOf(val))
		}
		return nil
	case reflect.Struct:
		if err := encodeStruct(m, rv, row); err != nil {
			return err
		}
		return nil
	default:
		return errs.InvalidArgument("output must point to a struct or map")
	}
}

// encodeStruct fills db-tagged fields from a row, recursing into embedded
// structs so nested fields such as entity.Entity.ID are restored.
func encodeStruct(m Model, rv reflect.Value, row map[string]any) error {
	t := rv.Type()
	for i := 0; i < t.NumField(); i++ {
		sf := t.Field(i)
		if sf.PkgPath != "" {
			continue
		}
		fv := rv.Field(i)
		if sf.Anonymous && fv.Kind() == reflect.Struct && fv.Type() != reflect.TypeOf(time.Time{}) {
			if err := encodeStruct(m, fv, row); err != nil {
				return err
			}
			continue
		}
		name := sf.Tag.Get(dbTag)
		if name == "" {
			name = strings.ToLower(sf.Name)
		}
		if name == "-" {
			continue
		}
		val, ok := row[name]
		if !ok {
			continue
		}
		if err := setValue(fv, val); err != nil {
			return fmt.Errorf("field %s: %w", name, err)
		}
	}
	return nil
}

// DecodeList fills a pointer-to-slice with records decoded from rows.
func DecodeList(m Model, rows []map[string]any, out any) error {
	rv := reflect.ValueOf(out)
	if rv.Kind() != reflect.Ptr || rv.IsNil() {
		return errs.InvalidArgument("output must be a non-nil pointer")
	}
	rv = rv.Elem()
	if rv.Kind() != reflect.Slice {
		return errs.InvalidArgument("output must point to a slice")
	}
	elemType := rv.Type().Elem()
	for _, row := range rows {
		if elemType.Kind() == reflect.Map {
			em := reflect.MakeMap(elemType)
			for k, v := range row {
				em.SetMapIndex(reflect.ValueOf(k), reflect.ValueOf(v))
			}
			rv.Set(reflect.Append(rv, em))
			continue
		}
		ev := reflect.New(elemType)
		if err := Encode(m, row, ev.Interface()); err != nil {
			return err
		}
		rv.Set(reflect.Append(rv, ev.Elem()))
	}
	return nil
}

// normalize converts reflect values into plain storable values.
func normalize(v reflect.Value) any {
	if v.Kind() == reflect.Interface {
		if v.IsNil() {
			return nil
		}
		v = v.Elem()
	}
	switch v.Kind() {
	case reflect.Ptr:
		if v.IsNil() {
			return nil
		}
		return normalize(v.Elem())
	case reflect.String:
		return v.String()
	case reflect.Int64, reflect.Int32, reflect.Int, reflect.Float64, reflect.Float32, reflect.Bool:
		return v.Interface()
	case reflect.Uint64, reflect.Uint32, reflect.Uint:
		// Named uint types that render to a string (e.g. identity.NodeID) must
		// be stored as their text form — a bare integer can't bind to a TEXT
		// column in the SQL drivers.
		if s, ok := v.Interface().(interface{ String() string }); ok {
			return s.String()
		}
		return int64(v.Uint())
	case reflect.Struct:
		if t, ok := v.Interface().(time.Time); ok {
			return t
		}
		if s, ok := v.Interface().(interface{ String() string }); ok {
			return s.String()
		}
		b, err := json.Marshal(v.Interface())
		if err == nil {
			return json.RawMessage(b)
		}
		return v.Interface()
	case reflect.Slice, reflect.Array, reflect.Map:
		b, err := json.Marshal(v.Interface())
		if err == nil {
			return json.RawMessage(b)
		}
		return v.Interface()
	default:
		return v.Interface()
	}
}

// setValue assigns a stored value into a struct field.
func setValue(f reflect.Value, val any) error {
	if val == nil {
		return nil
	}
	if f.Kind() == reflect.Ptr {
		if f.IsNil() {
			f.Set(reflect.New(f.Type().Elem()))
		}
		f = f.Elem()
	}
	switch f.Kind() {
	case reflect.String:
		switch v := val.(type) {
		case string:
			f.SetString(v)
		case []byte:
			f.SetString(string(v))
		default:
			rv := reflect.ValueOf(val)
			if rv.Kind() == reflect.String {
				f.SetString(rv.String())
			} else {
				f.SetString(toStr(v))
			}
		}
	case reflect.Int64, reflect.Int, reflect.Int32:
		f.SetInt(toInt64(val))
	case reflect.Uint64, reflect.Uint, reflect.Uint32:
		f.SetUint(toUint64(val))
	case reflect.Float64, reflect.Float32:
		f.SetFloat(toFloat64(val))
	case reflect.Bool:
		f.SetBool(toBool(val))
	case reflect.Struct:
		if f.Type() == reflect.TypeOf(time.Time{}) {
			if t, ok := val.(time.Time); ok {
				f.Set(reflect.ValueOf(t))
			} else if s, ok := val.(string); ok {
				if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
					f.Set(reflect.ValueOf(t))
				}
			}
			return nil
		}
		// Scalar value objects (such as identity.ID) persist their String form;
		// ordinary structs persist JSON, returned as text/bytes by SQL drivers.
		var b []byte
		var err error
		if _, scalar := f.Interface().(fmt.Stringer); scalar {
			b, err = json.Marshal(val)
		} else {
			b, err = jsonBytes(val)
		}
		if err != nil {
			return err
		}
		return json.Unmarshal(b, f.Addr().Interface())
	case reflect.Slice, reflect.Map:
		b, err := jsonBytes(val)
		if err != nil {
			return err
		}
		return json.Unmarshal(b, f.Addr().Interface())
	default:
		return errs.InvalidArgument("unsupported field kind " + f.Kind().String())
	}
	return nil
}

func toStr(v any) string {
	rv := reflect.ValueOf(v)
	if rv.IsValid() && rv.Kind() == reflect.String {
		return rv.String()
	}
	switch t := v.(type) {
	case string:
		return t
	case []byte:
		return string(t)
	case json.RawMessage:
		return string(t)
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

// jsonBytes renders a stored value as the raw JSON bytes it represents. JSON
// columns come back from SQL drivers as a string (or []byte) of JSON text and
// from the memory engine as json.RawMessage; all three must be used verbatim.
// Anything else is marshalled.
func jsonBytes(v any) ([]byte, error) {
	switch t := v.(type) {
	case string:
		return []byte(t), nil
	case []byte:
		return t, nil
	case json.RawMessage:
		return t, nil
	default:
		return json.Marshal(v)
	}
}

func toInt64(v any) int64 {
	switch t := v.(type) {
	case int64:
		return t
	case int:
		return int64(t)
	case int32:
		return int64(t)
	case uint64:
		return int64(t)
	case float64:
		return int64(t)
	case json.Number:
		i, _ := t.Int64()
		return i
	default:
		b, _ := json.Marshal(v)
		var n json.Number
		_ = json.Unmarshal(b, &n)
		i, _ := n.Int64()
		return i
	}
}

func toUint64(v any) uint64 {
	switch t := v.(type) {
	case uint64:
		return t
	case uint:
		return uint64(t)
	case int64:
		return uint64(t)
	case int:
		return uint64(t)
	case float64:
		return uint64(t)
	default:
		b, _ := json.Marshal(v)
		var n json.Number
		_ = json.Unmarshal(b, &n)
		i, _ := n.Int64()
		return uint64(i)
	}
}

func toFloat64(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case float32:
		return float64(t)
	case int64:
		return float64(t)
	case json.Number:
		f, _ := t.Float64()
		return f
	default:
		b, _ := json.Marshal(v)
		var n json.Number
		_ = json.Unmarshal(b, &n)
		f, _ := n.Float64()
		return f
	}
}

func toBool(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}
