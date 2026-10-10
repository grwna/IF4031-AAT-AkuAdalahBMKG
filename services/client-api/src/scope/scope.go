package scope

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	ReadSummary = "hazards:read:summary"
	ReadRaw     = "hazards:read:raw"
)

type Access int

const (
	AccessNone Access = iota
	AccessSummary
	AccessRaw
)

var (
	ErrInsufficientScope = errors.New("insufficient scope")
	ErrInvalidFields     = errors.New("invalid fields")
)

var summaryFields = map[string]bool{
	"hazard_id":   true,
	"source":      true,
	"hazard_type": true,
	"severity":    true,
	"area_name":   true,
	"occurred_at": true,
	"ingested_at": true,
}

var rawFields = map[string]bool{
	"source_ref_id": true,
	"latitude":      true,
	"longitude":     true,
	"attributes":    true,
}

var RawViewFields = []string{"hazard_id", "source_ref_id", "latitude", "longitude", "attributes"}

type scopeChecker interface {
	HasScope(scope string) bool
}

func AccessFor(c scopeChecker) Access {
	switch {
	case c.HasScope(ReadRaw):
		return AccessRaw
	case c.HasScope(ReadSummary):
		return AccessSummary
	default:
		return AccessNone
	}
}

func ParseFields(raw string) ([]string, error) {
	var fields []string
	seen := map[string]bool{}
	for _, name := range strings.Split(raw, ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, fmt.Errorf("%w: empty field name", ErrInvalidFields)
		}
		if !summaryFields[name] && !rawFields[name] {
			return nil, fmt.Errorf("%w: unknown field %q", ErrInvalidFields, name)
		}
		if !seen[name] {
			seen[name] = true
			fields = append(fields, name)
		}
	}
	return fields, nil
}

func Authorize(access Access, fields []string) error {
	switch access {
	case AccessRaw:
		return nil
	case AccessSummary:
		if raw := RawFieldsIn(fields); len(raw) > 0 {
			return fmt.Errorf("%w: raw fields %s require %s", ErrInsufficientScope, strings.Join(raw, ","), ReadRaw)
		}
		return nil
	default:
		return fmt.Errorf("%w: requires %s or %s", ErrInsufficientScope, ReadSummary, ReadRaw)
	}
}

func RawFieldsIn(fields []string) []string {
	var raw []string
	for _, f := range fields {
		if rawFields[f] {
			raw = append(raw, f)
		}
	}
	return raw
}

func Project(obj map[string]json.RawMessage, access Access, fields []string) map[string]json.RawMessage {
	if len(fields) > 0 {
		return pick(obj, fields)
	}
	if access == AccessRaw {
		return obj
	}
	out := make(map[string]json.RawMessage, len(summaryFields))
	for k, v := range obj {
		if summaryFields[k] {
			out[k] = v
		}
	}
	return out
}

func pick(obj map[string]json.RawMessage, fields []string) map[string]json.RawMessage {
	out := make(map[string]json.RawMessage, len(fields))
	for _, f := range fields {
		if v, ok := obj[f]; ok {
			out[f] = v
		}
	}
	return out
}
