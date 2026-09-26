package store_test

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/store"
)

func TestStore_SeedAndFilter(t *testing.T) {
	st := store.NewMemoryStore()
	generator.Seed(st, 20)

	allSeismic := st.GetSeismicEvents(time.Time{})
	if len(allSeismic) < 20 {
		t.Fatalf("expected at least 20 seeded seismic events, got %d", len(allSeismic))
	}

	cutoff := time.Now().Add(-1 * time.Hour)
	recent := st.GetSeismicEvents(cutoff)
	for _, ev := range recent {
		if ev.OccurredAt.Before(cutoff) {
			t.Fatalf("expected event occurred_at >= %v, got %v", cutoff, ev.OccurredAt)
		}
	}
}

func TestStore_AddEventWithTsunami(t *testing.T) {
	st := store.NewMemoryStore()
	eventID := "bmkg-test-1"
	warningID := "tsunami-test-1"

	ev := models.SeismicEvent{
		EventID:          eventID,
		Magnitude:        7.2,
		DepthKM:          10.0,
		EpicenterLat:     -6.2,
		EpicenterLon:     105.1,
		RegionName:       "Selat Sunda",
		OccurredAt:       time.Now(),
		PotentialTsunami: true,
	}
	warn := &models.TsunamiWarning{
		WarningID:        warningID,
		RelatedEventID:   eventID,
		ThreatLevel:      models.ThreatLevelAwas,
		AffectedZones:    []string{"Banten", "Lampung Selatan"},
		EstimatedArrival: time.Now().Add(20 * time.Minute),
	}

	st.AddSeismicEvent(ev, warn)

	seismicList := st.GetSeismicEvents(time.Time{})
	if len(seismicList) != 1 {
		t.Fatalf("expected 1 seismic event, got %d", len(seismicList))
	}

	warnings := st.GetTsunamiWarnings(time.Time{})
	if len(warnings) != 1 {
		t.Fatalf("expected 1 tsunami warning, got %d", len(warnings))
	}
	if warnings[0].RelatedEventID != eventID {
		t.Fatalf("expected warning related_event_id %s, got %s", eventID, warnings[0].RelatedEventID)
	}
}
