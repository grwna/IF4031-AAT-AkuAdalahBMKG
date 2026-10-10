package mapping

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)

func TestMapSeismicToHazard(t *testing.T) {
	now := time.Now().UTC()
	occurredAt := now.Add(-10 * time.Minute)
	eta := now.Add(15 * time.Minute)

	t.Run("Seismic with Tsunami Warning AWAS", func(t *testing.T) {
		seismic := domain.SeismicEvent{
			EventID:          "bmkg-001",
			OccurredAt:       occurredAt,
			EpicenterLat:     -0.89,
			EpicenterLon:     119.87,
			DepthKM:          10.0,
			Magnitude:        7.2,
			RegionName:       "Sulawesi Tengah",
			PotentialTsunami: true,
		}
		warning := &domain.TsunamiWarning{
			WarningID:        "tw-001",
			RelatedEventID:   "bmkg-001",
			ThreatLevel:      "AWAS",
			AffectedZones:    []string{"Palu", "Donggala"},
			EstimatedArrival: &eta,
		}

		event := MapSeismicToHazard(seismic, warning, now)

		if event.HazardID != "BMKG-bmkg-001" {
			t.Errorf("expected HazardID BMKG-bmkg-001, got %s", event.HazardID)
		}
		if event.Source != domain.SourceBMKG {
			t.Errorf("expected Source BMKG, got %s", event.Source)
		}
		if event.SourceRefID != "bmkg-001" {
			t.Errorf("expected SourceRefID bmkg-001, got %s", event.SourceRefID)
		}
		if event.HazardType != domain.HazardTypeSeismic {
			t.Errorf("expected HazardType SEISMIC, got %s", event.HazardType)
		}
		if event.Severity != domain.SeverityAwas {
			t.Errorf("expected Severity AWAS, got %s", event.Severity)
		}
		if event.AreaName != "Sulawesi Tengah" {
			t.Errorf("expected AreaName Sulawesi Tengah, got %s", event.AreaName)
		}
		if event.Latitude == nil || *event.Latitude != -0.89 {
			t.Errorf("expected Latitude -0.89, got %v", event.Latitude)
		}
		if event.Longitude == nil || *event.Longitude != 119.87 {
			t.Errorf("expected Longitude 119.87, got %v", event.Longitude)
		}

		// Check attributes
		mag, ok := event.Attributes["magnitude"].(float64)
		if !ok || mag != 7.2 {
			t.Errorf("expected magnitude 7.2 in attributes, got %v", event.Attributes["magnitude"])
		}
	})

	t.Run("Seismic without warning - Magnitude >= 6.5 -> SIAGA", func(t *testing.T) {
		seismic := domain.SeismicEvent{
			EventID:      "bmkg-002",
			OccurredAt:   occurredAt,
			Magnitude:    6.8,
			RegionName:   "Maluku",
			EpicenterLat: -3.5,
			EpicenterLon: 128.0,
		}

		event := MapSeismicToHazard(seismic, nil, now)

		if event.Severity != domain.SeveritySiaga {
			t.Errorf("expected Severity SIAGA for magnitude 6.8, got %s", event.Severity)
		}
	})

	t.Run("Seismic without warning - Magnitude >= 5.0 -> WASPADA", func(t *testing.T) {
		seismic := domain.SeismicEvent{
			EventID:      "bmkg-003",
			OccurredAt:   occurredAt,
			Magnitude:    5.5,
			RegionName:   "Jawa Barat",
			EpicenterLat: -6.9,
			EpicenterLon: 107.6,
		}

		event := MapSeismicToHazard(seismic, nil, now)

		if event.Severity != domain.SeverityWaspada {
			t.Errorf("expected Severity WASPADA for magnitude 5.5, got %s", event.Severity)
		}
	})

	t.Run("Seismic without warning - Magnitude < 5.0 -> NORMAL", func(t *testing.T) {
		seismic := domain.SeismicEvent{
			EventID:      "bmkg-004",
			OccurredAt:   occurredAt,
			Magnitude:    4.2,
			RegionName:   "Bali",
			EpicenterLat: -8.4,
			EpicenterLon: 115.2,
		}

		event := MapSeismicToHazard(seismic, nil, now)

		if event.Severity != domain.SeverityNormal {
			t.Errorf("expected Severity NORMAL for magnitude 4.2, got %s", event.Severity)
		}
	})
}

func TestMapVolcanicToHazard(t *testing.T) {
	now := time.Now().UTC()

	t.Run("Known Volcano (Merapi) with AWAS Alert Level", func(t *testing.T) {
		volcanic := domain.VolcanicReport{
			ReportID:         "pvmbg-101",
			VolcanoID:        "v-merapi",
			ReportedAt:       now,
			AlertLevel:       "AWAS",
			EruptionCount24h: 5,
			AshColumnHeightM: 1500,
			RawFields: map[string]any{
				"report_id":            "pvmbg-101",
				"volcano_id":           "v-merapi",
				"alert_level":          "AWAS",
				"reported_at":          now,
				"seismic_events_count": 42,
			},
		}

		event := MapVolcanicToHazard(volcanic, now)

		if event.HazardID != "PVMBG-pvmbg-101" {
			t.Errorf("expected HazardID PVMBG-pvmbg-101, got %s", event.HazardID)
		}
		if event.Source != domain.SourcePVMBG {
			t.Errorf("expected Source PVMBG, got %s", event.Source)
		}
		if event.SourceRefID != "pvmbg-101" {
			t.Errorf("expected SourceRefID pvmbg-101, got %s", event.SourceRefID)
		}
		if event.HazardType != domain.HazardTypeVolcanic {
			t.Errorf("expected HazardType VOLCANIC, got %s", event.HazardType)
		}
		if event.Severity != domain.SeverityAwas {
			t.Errorf("expected Severity AWAS, got %s", event.Severity)
		}
		if event.AreaName != "Gunung Merapi" {
			t.Errorf("expected AreaName Gunung Merapi, got %s", event.AreaName)
		}
		if event.Latitude == nil || *event.Latitude != -7.5407 {
			t.Errorf("expected Latitude -7.5407, got %v", event.Latitude)
		}
		if event.Longitude == nil || *event.Longitude != 110.4457 {
			t.Errorf("expected Longitude 110.4457, got %v", event.Longitude)
		}

		// Verify dynamic raw fields attribute mapping
		seismicEvents, ok := event.Attributes["seismic_events_count"].(int)
		if !ok || seismicEvents != 42 {
			t.Errorf("expected seismic_events_count 42 in attributes, got %v", event.Attributes["seismic_events_count"])
		}
	})

	t.Run("Unknown Volcano with WASPADA Alert Level", func(t *testing.T) {
		volcanic := domain.VolcanicReport{
			ReportID:   "pvmbg-102",
			VolcanoID:  "v-unknown",
			ReportedAt: now,
			AlertLevel: "WASPADA",
		}

		event := MapVolcanicToHazard(volcanic, now)

		if event.AreaName != "v-unknown" {
			t.Errorf("expected AreaName fallback to v-unknown, got %s", event.AreaName)
		}
		if event.Latitude != nil || event.Longitude != nil {
			t.Errorf("expected nil coordinates for unknown volcano, got %v, %v", event.Latitude, event.Longitude)
		}
		if event.Severity != domain.SeverityWaspada {
			t.Errorf("expected Severity WASPADA, got %s", event.Severity)
		}
	})
}
