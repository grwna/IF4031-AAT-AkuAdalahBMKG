package event_test

import (
	"errors"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/event"
)

const validBody = `{
  "hazard_id": "BMKG-bmkg-0021",
  "source": "BMKG",
  "source_ref_id": "bmkg-0021",
  "hazard_type": "SEISMIC",
  "severity": "SIAGA",
  "area_name": "Sulawesi Tengah",
  "latitude": -0.89,
  "longitude": 119.87,
  "occurred_at": "2026-10-01T10:14:55Z",
  "ingested_at": "2026-10-01T10:14:58Z",
  "attributes": {"magnitude": 6.8, "potential_tsunami": true}
}`

func TestDecode_Valid(t *testing.T) {
	ev, err := event.Decode([]byte(validBody))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ev.HazardID != "BMKG-bmkg-0021" || ev.HazardType != "SEISMIC" || ev.Severity != "SIAGA" {
		t.Errorf("unexpected fields: %+v", ev)
	}
	if ev.Latitude == nil || *ev.Latitude != -0.89 {
		t.Errorf("expected latitude -0.89, got %v", ev.Latitude)
	}
	if !ev.OccurredAt.Equal(time.Date(2026, 10, 1, 10, 14, 55, 0, time.UTC)) {
		t.Errorf("unexpected occurred_at: %v", ev.OccurredAt)
	}
	if ev.Attributes["magnitude"] != 6.8 {
		t.Errorf("expected magnitude 6.8 in attributes, got %v", ev.Attributes["magnitude"])
	}
}

func TestDecode_IgnoresUnknownFields(t *testing.T) {
	body := `{"hazard_id":"PVMBG-pvmbg-0034","severity":"WASPADA","new_top_level_field":"x","attributes":{"confidence_level":0.87}}`

	ev, err := event.Decode([]byte(body))
	if err != nil {
		t.Fatalf("unknown fields must not cause an error: %v", err)
	}
	if ev.Attributes["confidence_level"] != 0.87 {
		t.Errorf("expected confidence_level kept in attributes, got %v", ev.Attributes)
	}
}

func TestDecode_NullCoordinates(t *testing.T) {
	body := `{"hazard_id":"PVMBG-pvmbg-0099","latitude":null,"longitude":null}`

	ev, err := event.Decode([]byte(body))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ev.Latitude != nil || ev.Longitude != nil {
		t.Errorf("expected nil coordinates, got %v / %v", ev.Latitude, ev.Longitude)
	}
}

func TestDecode_Invalid(t *testing.T) {
	cases := map[string]string{
		"not json":        `hello`,
		"truncated json":  `{"hazard_id":"BMKG-1"`,
		"json array":      `[{"hazard_id":"BMKG-1"}]`,
		"json null":       `null`,
		"empty object":    `{}`,
		"empty hazard_id": `{"hazard_id":""}`,
		"wrong type":      `{"hazard_id":123}`,
		"bad timestamp":   `{"hazard_id":"BMKG-1","occurred_at":"yesterday"}`,
		"empty body":      ``,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := event.Decode([]byte(body))
			if !errors.Is(err, event.ErrInvalidMessage) {
				t.Fatalf("expected ErrInvalidMessage, got %v", err)
			}
		})
	}
}
