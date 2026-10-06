package event

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var ErrInvalidMessage = errors.New("invalid hazard event message")

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
}

func Decode(body []byte) (HazardEvent, error) {
	var ev HazardEvent
	if err := json.Unmarshal(body, &ev); err != nil {
		return HazardEvent{}, fmt.Errorf("%w: %v", ErrInvalidMessage, err)
	}
	if ev.HazardID == "" {
		return HazardEvent{}, fmt.Errorf("%w: hazard_id is empty", ErrInvalidMessage)
	}
	return ev, nil
}
