package idempotency_test

import (
	"sync"
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/consumer-notifier/src/idempotency"
)

func TestMemory_MarkIfNew(t *testing.T) {
	s := idempotency.NewMemory()

	if !s.MarkIfNew("BMKG-bmkg-0021:SIAGA") {
		t.Fatal("first MarkIfNew for a key must return true")
	}
	if s.MarkIfNew("BMKG-bmkg-0021:SIAGA") {
		t.Fatal("second MarkIfNew for the same key must return false")
	}
	if !s.MarkIfNew("BMKG-bmkg-0021:AWAS") {
		t.Fatal("a different key must be treated as new")
	}
}

func TestMemory_ConcurrentMarkIfNewOnlyOneWins(t *testing.T) {
	s := idempotency.NewMemory()

	const n = 50
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins := 0
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if s.MarkIfNew("same-key") {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if wins != 1 {
		t.Fatalf("expected exactly 1 winner, got %d", wins)
	}
}
