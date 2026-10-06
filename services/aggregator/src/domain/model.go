package domain

import (
	"encoding/json"
	"time"
)

// StatusEnum merepresentasikan status kesehatan polling sumber (UP / DEGRADED)
type SourceStatusType string

const (
	SourceStatusUp       SourceStatusType = "UP"
	SourceStatusDegraded SourceStatusType = "DEGRADED"
)

// Enum untuk Jenis Bahaya & Sumber
const (
	SourceBMKG  = "BMKG"
	SourcePVMBG = "PVMBG"

	HazardTypeSeismic  = "SEISMIC"
	HazardTypeVolcanic = "VOLCANIC"

	SeverityNormal  = "NORMAL"
	SeverityWaspada = "WASPADA"
	SeveritySiaga   = "SIAGA"
	SeverityAwas    = "AWAS"
)

// HazardEvent merepresentasikan entitas kanonik sesuai spesifikasi API Internal Aggregator (§3.1)
type HazardEvent struct {
	HazardID    string         `json:"hazard_id"`
	Source      string         `json:"source"`        // "BMKG" atau "PVMBG"
	SourceRefID string         `json:"source_ref_id"` // ID asli dari sumber
	HazardType  string         `json:"hazard_type"`   // "SEISMIC" atau "VOLCANIC"
	Severity    string         `json:"severity"`      // "NORMAL", "WASPADA", "SIAGA", "AWAS"
	AreaName    string         `json:"area_name"`
	Latitude    *float64       `json:"latitude"`   // Nullable jika koordinat tidak diketahui
	Longitude   *float64       `json:"longitude"`  // Nullable jika koordinat tidak diketahui
	OccurredAt  time.Time      `json:"occurred_at"`
	IngestedAt  time.Time      `json:"ingested_at"`
	Attributes  map[string]any `json:"attributes"` // Fleksibel: menampung field mentah & field dinamis baru
	IsPublished bool           `json:"-"`          // Status pengiriman pesan ke broker (internal outbox)
}

// SourceStatus merepresentasikan status kesegaran data per sumber (§3.2)
type SourceStatus struct {
	Status        SourceStatusType `json:"status"`          // "UP" atau "DEGRADED"
	LastSuccessAt *time.Time       `json:"last_success_at"` // Nullable
	StaleSince    *time.Time       `json:"stale_since"`     // Nullable
	LastError     *string          `json:"last_error"`      // Nullable
}

// MapSourceStatus menampung status untuk BMKG dan PVMBG
type MapSourceStatus map[string]SourceStatus

// Struct data mentah dari API BMKG (SeismicEvent)
type SeismicEvent struct {
	EventID          string    `json:"event_id"`
	Magnitude        float64   `json:"magnitude"`
	DepthKM          float64   `json:"depth_km"`
	EpicenterLat     float64   `json:"epicenter_lat"`
	EpicenterLon     float64   `json:"epicenter_lon"`
	RegionName       string    `json:"region_name"`
	OccurredAt       time.Time `json:"occurred_at"`
	PotentialTsunami bool      `json:"potential_tsunami"`
}

// Struct data mentah dari API BMKG (TsunamiWarning)
type TsunamiWarning struct {
	WarningID        string     `json:"warning_id"`
	RelatedEventID   string     `json:"related_event_id"`
	ThreatLevel      string     `json:"threat_level"` // "Waspada", "Siaga", "Awas"
	AffectedZones    []string   `json:"affected_zones"`
	EstimatedArrival *time.Time `json:"estimated_arrival,omitempty"`
}

// Struct data mentah dari API PVMBG (VolcanicReport)
// Menggunakan raw JSON / dynamic decoding untuk mendukung field baru tanpa breaking change (Problem 1)
type VolcanicReport struct {
	ReportID          string         `json:"report_id"`
	VolcanoID         string         `json:"volcano_id"`
	AlertLevel        string         `json:"alert_level"` // "Normal", "Waspada", "Siaga", "Awas"
	EruptionCount24h  int            `json:"eruption_count_24h"`
	AshColumnHeightM  float64        `json:"ash_column_height_m"`
	ReportedAt        time.Time      `json:"reported_at"`
	RawFields         map[string]any `json:"-"` // Menyimpan seluruh field JSON mentah
}

// UnmarshalJSON kustom untuk VolcanicReport agar field baru (seperti confidence_level) tidak hilang
func (v *VolcanicReport) UnmarshalJSON(data []byte) error {
	type Alias VolcanicReport
	aux := &struct {
		*Alias
	}{
		Alias: (*Alias)(v),
	}
	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}
	// Decode seluruh map JSON untuk menangkap field tak dikenal
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	v.RawFields = raw
	return nil
}

// Struct untuk Pagination Keyset (Cursor)
type CursorPayload struct {
	OccurredAt time.Time `json:"o"`
	HazardID   string    `json:"id"`
}

// Response standar error sesuai spesifikasi §2
type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type APIErrorResponse struct {
	Error APIError `json:"error"`
}
