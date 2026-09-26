package generator_test

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/generator"
)

func TestGenerateSeismicEvent(t *testing.T) {
	now := time.Now()
	ev, warn := generator.GenerateSeismicEvent("ev-1", "tsunami-1", now)

	if ev.EventID != "ev-1" {
		t.Fatalf("expected event ID ev-1, got %s", ev.EventID)
	}
	if ev.Magnitude < 3.5 || ev.Magnitude > 8.0 {
		t.Fatalf("magnitude %f out of expected range", ev.Magnitude)
	}
	if ev.PotentialTsunami && warn == nil {
		t.Fatal("expected tsunami warning when potential_tsunami is true")
	}
	if !ev.PotentialTsunami && warn != nil {
		t.Fatal("expected no tsunami warning when potential_tsunami is false")
	}
}
