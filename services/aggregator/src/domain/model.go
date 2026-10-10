package domain

import (
	"encoding/json"
	"time"
)

type SourceStatusType string

const (
	SourceStatusUp       SourceStatusType = "UP"
	SourceStatusDegraded SourceStatusType = "DEGRADED"
)

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

type HazardEvent struct {
	HazardID    string         `json:"hazard_id"`
	Source      string         `json:"source"`
	SourceRefID string         `json:"source_ref_id"`
	HazardType  string         `json:"hazard_type"`
	Severity    string         `json:"severity"`
	AreaName    string         `json:"area_name"`
	Latitude    *float64       `json:"latitude"`
	Longitude   *float64       `json:"longitude"`
	OccurredAt  time.Time      `json:"occurred_at"`
	IngestedAt  time.Time      `json:"ingested_at"`
	Attributes  map[string]any `json:"attributes"`
	IsPublished bool           `json:"-"`
}

type SourceStatus struct {
	Status        SourceStatusType `json:"status"`
	LastSuccessAt *time.Time       `json:"last_success_at"`
	StaleSince    *time.Time       `json:"stale_since"`
	LastError     *string          `json:"last_error"`
}

type MapSourceStatus map[string]SourceStatus

type SeismicEvent struct {
	EventID          string         `json:"event_id"`
	Magnitude        float64        `json:"magnitude"`
	DepthKM          float64        `json:"depth_km"`
	EpicenterLat     float64        `json:"epicenter_lat"`
	EpicenterLon     float64        `json:"epicenter_lon"`
	RegionName       string         `json:"region_name"`
	OccurredAt       time.Time      `json:"occurred_at"`
	PotentialTsunami bool           `json:"potential_tsunami"`
	RawFields        map[string]any `json:"-"`
}

func (s *SeismicEvent) UnmarshalJSON(data []byte) error {
	type Alias SeismicEvent
	aux := &struct {
		*Alias
	}{
		Alias: (*Alias)(s),
	}
	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	s.RawFields = raw
	return nil
}

type TsunamiWarning struct {
	WarningID        string         `json:"warning_id"`
	RelatedEventID   string         `json:"related_event_id"`
	ThreatLevel      string         `json:"threat_level"`
	AffectedZones    []string       `json:"affected_zones"`
	EstimatedArrival *time.Time     `json:"estimated_arrival,omitempty"`
	RawFields        map[string]any `json:"-"`
}

func (t *TsunamiWarning) UnmarshalJSON(data []byte) error {
	type Alias TsunamiWarning
	aux := &struct {
		*Alias
	}{
		Alias: (*Alias)(t),
	}
	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	t.RawFields = raw
	return nil
}

type VolcanicReport struct {
	ReportID         string         `json:"report_id"`
	VolcanoID        string         `json:"volcano_id"`
	AlertLevel       string         `json:"alert_level"`
	EruptionCount24h int            `json:"eruption_count_24h"`
	AshColumnHeightM float64        `json:"ash_column_height_m"`
	ReportedAt       time.Time      `json:"reported_at"`
	RawFields        map[string]any `json:"-"`
}

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

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	v.RawFields = raw
	return nil
}

type CursorPayload struct {
	OccurredAt time.Time `json:"o"`
	HazardID   string    `json:"id"`
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type APIErrorResponse struct {
	Error APIError `json:"error"`
}
