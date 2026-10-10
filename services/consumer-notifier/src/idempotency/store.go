package idempotency

import "sync"

// records keys that have already been processed for idempotency.
type Store interface {
	MarkIfNew(key string) bool
}

// In memory: keys are lost on restart, so it only guarantees dedup within a single process lifetime.
type Memory struct {
	mu   sync.Mutex
	seen map[string]struct{}
}

func NewMemory() *Memory {
	return &Memory{seen: make(map[string]struct{})}
}

func (m *Memory) MarkIfNew(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.seen[key]; ok {
		return false
	}
	m.seen[key] = struct{}{}
	return true
}
