package polling

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)

func TestStatusTracker(t *testing.T) {
	tracker := NewStatusTracker()
	now := time.Now().UTC()

	// 1. Initial status should be UP for both sources
	st := tracker.GetStatus()
	if st[domain.SourceBMKG].Status != domain.SourceStatusUp {
		t.Errorf("expected initial BMKG status UP, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourcePVMBG].Status != domain.SourceStatusUp {
		t.Errorf("expected initial PVMBG status UP, got %s", st[domain.SourcePVMBG].Status)
	}

	// 2. SetSuccess updates LastSuccessAt and clears error/stale
	tracker.SetSuccess(domain.SourceBMKG, now)
	st = tracker.GetStatus()
	if st[domain.SourceBMKG].LastSuccessAt == nil {
		t.Fatal("expected LastSuccessAt to be set after SetSuccess")
	}
	if !st[domain.SourceBMKG].LastSuccessAt.Equal(now) {
		t.Errorf("expected LastSuccessAt %v, got %v", now, *st[domain.SourceBMKG].LastSuccessAt)
	}

	// 3. SetDegraded updates status to DEGRADED and sets LastError
	errMsg := "connection timeout"
	degradedTime := now.Add(5 * time.Second)
	tracker.SetDegraded(domain.SourceBMKG, degradedTime, errMsg)
	st = tracker.GetStatus()

	if st[domain.SourceBMKG].Status != domain.SourceStatusDegraded {
		t.Errorf("expected BMKG status DEGRADED, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourceBMKG].LastError == nil || *st[domain.SourceBMKG].LastError != errMsg {
		t.Errorf("expected LastError %s, got %v", errMsg, st[domain.SourceBMKG].LastError)
	}
	if st[domain.SourceBMKG].StaleSince == nil || !st[domain.SourceBMKG].StaleSince.Equal(now) {
		t.Errorf("expected StaleSince to retain last success time %v, got %v", now, st[domain.SourceBMKG].StaleSince)
	}

	// 4. Recover with SetSuccess
	recoverTime := degradedTime.Add(10 * time.Second)
	tracker.SetSuccess(domain.SourceBMKG, recoverTime)
	st = tracker.GetStatus()

	if st[domain.SourceBMKG].Status != domain.SourceStatusUp {
		t.Errorf("expected status UP after recovery, got %s", st[domain.SourceBMKG].Status)
	}
	if st[domain.SourceBMKG].StaleSince != nil {
		t.Errorf("expected StaleSince to be nil after recovery, got %v", st[domain.SourceBMKG].StaleSince)
	}
	if st[domain.SourceBMKG].LastError != nil {
		t.Errorf("expected LastError to be nil after recovery, got %v", st[domain.SourceBMKG].LastError)
	}
}
