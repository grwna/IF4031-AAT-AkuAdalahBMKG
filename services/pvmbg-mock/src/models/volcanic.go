package models

import "time"

type AlertLevel string

const (
	AlertLevelNormal  AlertLevel = "Normal"
	AlertLevelWaspada AlertLevel = "Waspada"
	AlertLevelSiaga   AlertLevel = "Siaga"
	AlertLevelAwas    AlertLevel = "Awas"
)

type VolcanicReport struct {
	ReportID         string     `json:"report_id"`
	VolcanoID        string     `json:"volcano_id"`
	AlertLevel       AlertLevel `json:"alert_level"`
	EruptionCount24h int        `json:"eruption_count_24h"`
	AshColumnHeightM float64    `json:"ash_column_height_m"`
	ReportedAt       time.Time  `json:"reported_at"`
	ConfidenceLevel  *float64   `json:"confidence_level,omitempty"`
}
