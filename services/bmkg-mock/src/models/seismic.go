package models

import "time"

type ThreatLevel string

const (
	ThreatLevelWaspada ThreatLevel = "Waspada"
	ThreatLevelSiaga   ThreatLevel = "Siaga"
	ThreatLevelAwas    ThreatLevel = "Awas"
)

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

type TsunamiWarning struct {
	WarningID        string      `json:"warning_id"`
	RelatedEventID   string      `json:"related_event_id"`
	ThreatLevel      ThreatLevel `json:"threat_level"`
	AffectedZones    []string    `json:"affected_zones"`
	EstimatedArrival time.Time   `json:"estimated_arrival"`
}
