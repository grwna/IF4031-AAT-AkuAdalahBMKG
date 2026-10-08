package mapping

import (
	"strings"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)

// VolcanoRef merepresentasikan data referensi lokasi gunung api milik BNPB
type VolcanoRef struct {
	Name string
	Lat  float64
	Lon  float64
}

// Tabel referensi statis gunung api (dikelola oleh BNPB)
var VolcanoTable = map[string]VolcanoRef{
	"v-merapi":   {Name: "Gunung Merapi", Lat: -7.5407, Lon: 110.4457},
	"merapi":     {Name: "Gunung Merapi", Lat: -7.5407, Lon: 110.4457},
	"v-sinabung": {Name: "Gunung Sinabung", Lat: 3.17, Lon: 98.392},
	"sinabung":   {Name: "Gunung Sinabung", Lat: 3.17, Lon: 98.392},
	"v-krakatau": {Name: "Anak Krakatau", Lat: -6.102, Lon: 105.423},
	"krakatau":   {Name: "Anak Krakatau", Lat: -6.102, Lon: 105.423},
	"v-agung":    {Name: "Gunung Agung", Lat: -8.342, Lon: 115.508},
	"agung":      {Name: "Gunung Agung", Lat: -8.342, Lon: 115.508},
	"v-semeru":   {Name: "Gunung Semeru", Lat: -8.108, Lon: 112.922},
	"semeru":     {Name: "Gunung Semeru", Lat: -8.108, Lon: 112.922},
	"v-marapi":   {Name: "Gunung Marapi", Lat: -0.381, Lon: 100.474},
	"marapi":     {Name: "Gunung Marapi", Lat: -0.381, Lon: 100.474},
	"v-lewotobi": {Name: "Gunung Lewotobi", Lat: -8.542, Lon: 122.775},
	"lewotobi":   {Name: "Gunung Lewotobi", Lat: -8.542, Lon: 122.775},
}

// MapSeismicToHazard mengubah data SeismicEvent dari BMKG menjadi HazardEvent Kanonik
func MapSeismicToHazard(seismic domain.SeismicEvent, warning *domain.TsunamiWarning, ingestedAt time.Time) domain.HazardEvent {
	// 1. Tentukan severity berdasarkan keberadaan TsunamiWarning dan Magnitude
	severity := domain.SeverityNormal
	if warning != nil {
		switch strings.ToUpper(warning.ThreatLevel) {
		case "AWAS":
			severity = domain.SeverityAwas
		case "SIAGA":
			severity = domain.SeveritySiaga
		case "WASPADA":
			severity = domain.SeverityWaspada
		default:
			severity = domain.SeveritySiaga
		}
	} else {
		if seismic.Magnitude >= 6.5 {
			severity = domain.SeveritySiaga
		} else if seismic.Magnitude >= 5.0 {
			severity = domain.SeverityWaspada
		} else {
			severity = domain.SeverityNormal
		}
	}

	// 2. Susun map attributes (menampung detail spesifik seismik & field dinamis baru)
	attrs := make(map[string]any)
	for k, v := range seismic.RawFields {
		// Abaikan field yang sudah dipetakan ke field kanonik utama
		if k == "event_id" || k == "region_name" || k == "epicenter_lat" || k == "epicenter_lon" || k == "occurred_at" {
			continue
		}
		attrs[k] = v
	}

	// Pastikan field standar seismik selalu ada
	if _, ok := attrs["magnitude"]; !ok {
		attrs["magnitude"] = seismic.Magnitude
	}
	if _, ok := attrs["depth_km"]; !ok {
		attrs["depth_km"] = seismic.DepthKM
	}
	if _, ok := attrs["potential_tsunami"]; !ok {
		attrs["potential_tsunami"] = seismic.PotentialTsunami
	}

	if warning != nil {
		warningAttrs := map[string]any{
			"warning_id":        warning.WarningID,
			"threat_level":      warning.ThreatLevel,
			"affected_zones":    warning.AffectedZones,
			"estimated_arrival": warning.EstimatedArrival,
		}
		// Masukkan field tambahan jika ada di TsunamiWarning
		for k, v := range warning.RawFields {
			if k == "warning_id" || k == "related_event_id" || k == "threat_level" || k == "affected_zones" || k == "estimated_arrival" {
				continue
			}
			warningAttrs[k] = v
		}
		attrs["tsunami_warning"] = warningAttrs
	}

	// 3. Format ID Kanonik: BMKG-<event_id>
	hazardID := "BMKG-" + seismic.EventID

	lat := seismic.EpicenterLat
	lon := seismic.EpicenterLon

	return domain.HazardEvent{
		HazardID:    hazardID,
		Source:      domain.SourceBMKG,
		SourceRefID: seismic.EventID,
		HazardType:  domain.HazardTypeSeismic,
		Severity:    severity,
		AreaName:    seismic.RegionName,
		Latitude:    &lat,
		Longitude:   &lon,
		OccurredAt:  seismic.OccurredAt,
		IngestedAt:  ingestedAt,
		Attributes:  attrs,
	}
}

// MapVolcanicToHazard mengubah data VolcanicReport dari PVMBG menjadi HazardEvent Kanonik
func MapVolcanicToHazard(volcanic domain.VolcanicReport, ingestedAt time.Time) domain.HazardEvent {
	// 1. Pemetaan Alert Level ke Severity Kanonik
	severity := domain.SeverityNormal
	switch strings.ToUpper(volcanic.AlertLevel) {
	case "AWAS":
		severity = domain.SeverityAwas
	case "SIAGA":
		severity = domain.SeveritySiaga
	case "WASPADA":
		severity = domain.SeverityWaspada
	default:
		severity = domain.SeverityNormal
	}

	// 2. Lookup nama & koordinat gunung api dari tabel referensi statis
	areaName := volcanic.VolcanoID
	var latPtr, lonPtr *float64

	if ref, ok := VolcanoTable[strings.ToLower(volcanic.VolcanoID)]; ok {
		areaName = ref.Name
		latVal := ref.Lat
		lonVal := ref.Lon
		latPtr = &latVal
		lonPtr = &lonVal
	}

	// 3. Menyusun attributes (memasukkan field standar & SEMUA field tak dikenal/dinamis)
	attrs := make(map[string]any)
	for k, v := range volcanic.RawFields {
		// Abaikan field yang sudah dipetakan ke kolom utama
		if k == "report_id" || k == "volcano_id" || k == "alert_level" || k == "reported_at" {
			continue
		}
		attrs[k] = v
	}

	// Pastikan field standar vulkanik ada di attributes jika tidak ada di RawFields
	if _, ok := attrs["eruption_count_24h"]; !ok {
		attrs["eruption_count_24h"] = volcanic.EruptionCount24h
	}
	if _, ok := attrs["ash_column_height_m"]; !ok {
		attrs["ash_column_height_m"] = volcanic.AshColumnHeightM
	}

	// Format ID Kanonik: PVMBG-<report_id>
	hazardID := "PVMBG-" + volcanic.ReportID

	return domain.HazardEvent{
		HazardID:    hazardID,
		Source:      domain.SourcePVMBG,
		SourceRefID: volcanic.ReportID,
		HazardType:  domain.HazardTypeVolcanic,
		Severity:    severity,
		AreaName:    areaName,
		Latitude:    latPtr,
		Longitude:   lonPtr,
		OccurredAt:  volcanic.ReportedAt,
		IngestedAt:  ingestedAt,
		Attributes:  attrs,
	}
}
