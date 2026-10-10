package store

import (
	"sync"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/models"
)

type MemoryStore struct {
	mu      sync.RWMutex
	reports []models.VolcanicReport
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		reports: make([]models.VolcanicReport, 0),
	}
}

func (s *MemoryStore) AddVolcanicReport(report models.VolcanicReport) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.reports = append(s.reports, report)
}

func (s *MemoryStore) GetVolcanicReports(since time.Time) []models.VolcanicReport {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make([]models.VolcanicReport, 0)
	for _, rep := range s.reports {
		if since.IsZero() || rep.ReportedAt.After(since) || rep.ReportedAt.Equal(since) {
			result = append(result, rep)
		}
	}
	return result
}

