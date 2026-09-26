package store

import (
	"sync"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/models"
)

type MemoryStore struct {
	mu             sync.RWMutex
	seismicEvents  []models.SeismicEvent
	tsunamiWarning []models.TsunamiWarning
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		seismicEvents:  make([]models.SeismicEvent, 0),
		tsunamiWarning: make([]models.TsunamiWarning, 0),
	}
}

func (s *MemoryStore) AddSeismicEvent(event models.SeismicEvent, warning *models.TsunamiWarning) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.seismicEvents = append(s.seismicEvents, event)
	if warning != nil {
		s.tsunamiWarning = append(s.tsunamiWarning, *warning)
	}
}

func (s *MemoryStore) GetSeismicEvents(since time.Time) []models.SeismicEvent {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make([]models.SeismicEvent, 0)
	for _, ev := range s.seismicEvents {
		if since.IsZero() || ev.OccurredAt.After(since) || ev.OccurredAt.Equal(since) {
			result = append(result, ev)
		}
	}
	return result
}

func (s *MemoryStore) GetTsunamiWarnings(since time.Time) []models.TsunamiWarning {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make([]models.TsunamiWarning, 0)
	for _, tw := range s.tsunamiWarning {
		if since.IsZero() || tw.EstimatedArrival.After(since) || tw.EstimatedArrival.Equal(since) {
			result = append(result, tw)
		}
	}
	return result
}

