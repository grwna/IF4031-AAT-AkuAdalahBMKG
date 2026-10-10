package scope_test

import (
	"encoding/json"
	"errors"
	"reflect"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/scope"
)

type fakeClaims string

func (f fakeClaims) HasScope(s string) bool {
	return slices.Contains(strings.Fields(string(f)), s)
}

const fullEvent = `{
	"hazard_id": "PVMBG-pvmbg-0034",
	"source": "PVMBG",
	"source_ref_id": "pvmbg-0034",
	"hazard_type": "VOLCANIC",
	"severity": "WASPADA",
	"area_name": "Gunung Merapi",
	"latitude": -7.5407,
	"longitude": 110.4457,
	"occurred_at": "2026-10-01T10:15:00Z",
	"ingested_at": "2026-10-01T10:15:03Z",
	"attributes": {"eruption_count_24h": 12, "confidence_level": 0.87},
	"future_canonical_field": "should not leak to media"
}`

func event(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(fullEvent), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func keys(m map[string]json.RawMessage) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestAccessFor(t *testing.T) {
	cases := map[string]scope.Access{
		"hazards:read:summary":                  scope.AccessSummary,
		"hazards:read:raw":                      scope.AccessRaw,
		"hazards:read:summary hazards:read:raw": scope.AccessRaw,
		"":                                      scope.AccessNone,
		"hazards:read":                          scope.AccessNone,
	}
	for in, want := range cases {
		if got := scope.AccessFor(fakeClaims(in)); got != want {
			t.Errorf("AccessFor(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestParseFields(t *testing.T) {
	got, err := scope.ParseFields(" severity, area_name ,severity")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := []string{"severity", "area_name"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestParseFields_Invalid(t *testing.T) {
	for _, in := range []string{"", "severity,", ",severity", "severity,,area_name", "password", "future_canonical_field"} {
		t.Run(in, func(t *testing.T) {
			if _, err := scope.ParseFields(in); !errors.Is(err, scope.ErrInvalidFields) {
				t.Errorf("ParseFields(%q) err = %v, want ErrInvalidFields", in, err)
			}
		})
	}
}

func TestAuthorize(t *testing.T) {
	cases := []struct {
		name   string
		access scope.Access
		fields []string
		allow  bool
	}{
		{"raw no fields", scope.AccessRaw, nil, true},
		{"raw with raw fields", scope.AccessRaw, []string{"latitude", "attributes"}, true},
		{"summary no fields", scope.AccessSummary, nil, true},
		{"summary with summary fields", scope.AccessSummary, []string{"severity", "area_name"}, true},
		{"summary with one raw field", scope.AccessSummary, []string{"severity", "latitude"}, false},
		{"summary raw view", scope.AccessSummary, scope.RawViewFields, false},
		{"none no fields", scope.AccessNone, nil, false},
		{"none summary fields", scope.AccessNone, []string{"severity"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := scope.Authorize(tc.access, tc.fields)
			if tc.allow && err != nil {
				t.Errorf("expected allow, got %v", err)
			}
			if !tc.allow && !errors.Is(err, scope.ErrInsufficientScope) {
				t.Errorf("expected ErrInsufficientScope, got %v", err)
			}
		})
	}
}

func TestProject_SummaryWhitelist(t *testing.T) {
	got := keys(scope.Project(event(t), scope.AccessSummary, nil))
	want := []string{"area_name", "hazard_id", "hazard_type", "ingested_at", "occurred_at", "severity", "source"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("summary keys = %v, want %v", got, want)
	}
}

func TestProject_RawPassesEverythingThrough(t *testing.T) {
	in := event(t)
	out := scope.Project(in, scope.AccessRaw, nil)
	if !reflect.DeepEqual(keys(out), keys(in)) {
		t.Errorf("raw keys = %v, want %v", keys(out), keys(in))
	}
	var attrs map[string]any
	if err := json.Unmarshal(out["attributes"], &attrs); err != nil {
		t.Fatal(err)
	}
	if attrs["confidence_level"] != 0.87 {
		t.Errorf("new attribute key lost: %v", attrs)
	}
}

func TestProject_SelectedFields(t *testing.T) {
	got := keys(scope.Project(event(t), scope.AccessSummary, []string{"severity", "area_name"}))
	if want := []string{"area_name", "severity"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}

	got = keys(scope.Project(event(t), scope.AccessRaw, scope.RawViewFields))
	if want := []string{"attributes", "hazard_id", "latitude", "longitude", "source_ref_id"}; !reflect.DeepEqual(got, want) {
		t.Errorf("raw view keys = %v, want %v", got, want)
	}
}

func TestProject_MissingSelectedFieldIsOmitted(t *testing.T) {
	in := event(t)
	delete(in, "latitude")
	got := keys(scope.Project(in, scope.AccessRaw, []string{"hazard_id", "latitude"}))
	if want := []string{"hazard_id"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}
