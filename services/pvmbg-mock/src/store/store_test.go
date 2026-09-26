package store_test

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/store"
)

func TestPVMBGStore_SeedAndFilter(t *testing.T) {
	st := store.NewMemoryStore()
	generator.Seed(st, 20)

	reports := st.GetVolcanicReports(time.Time{})
	if len(reports) < 20 {
		t.Fatalf("expected at least 20 seeded volcanic reports, got %d", len(reports))
	}

	for _, rep := range reports {
		if rep.ConfidenceLevel != nil {
			t.Fatalf("expected confidence_level to be nil for seeded reports before schema upgrade")
		}
	}

	newRep := generator.GenerateVolcanicReport("pvmbg-new-001", time.Now(), true)
	st.AddVolcanicReport(newRep)

	allReports := st.GetVolcanicReports(time.Time{})
	if len(allReports) != 21 {
		t.Fatalf("expected 21 total reports, got %d", len(allReports))
	}

	if allReports[0].ConfidenceLevel != nil {
		t.Fatal("expected old record to retain nil confidence level")
	}
	if allReports[20].ConfidenceLevel == nil {
		t.Fatal("expected new record to have confidence level")
	}
}

func TestPVMBGStore_AddReport(t *testing.T) {
	st := store.NewMemoryStore()
	conf := 0.85
	repWith := models.VolcanicReport{
		ReportID:         "pvmbg-rep-001",
		VolcanoID:        "merapi",
		AlertLevel:       models.AlertLevelSiaga,
		EruptionCount24h: 12,
		AshColumnHeightM: 1500.0,
		ReportedAt:       time.Now(),
		ConfidenceLevel:  &conf,
	}
	st.AddVolcanicReport(repWith)

	repWithout := models.VolcanicReport{
		ReportID:         "pvmbg-rep-002",
		VolcanoID:        "semeru",
		AlertLevel:       models.AlertLevelNormal,
		EruptionCount24h: 0,
		AshColumnHeightM: 100.0,
		ReportedAt:       time.Now(),
		ConfidenceLevel:  nil,
	}
	st.AddVolcanicReport(repWithout)

	res := st.GetVolcanicReports(time.Time{})
	if len(res) != 2 {
		t.Fatalf("expected 2 reports, got %d", len(res))
	}
	if res[0].ConfidenceLevel == nil || *res[0].ConfidenceLevel != 0.85 {
		t.Fatalf("expected confidence level 0.85, got %v", res[0].ConfidenceLevel)
	}
	if res[1].ConfidenceLevel != nil {
		t.Fatalf("expected nil confidence level, got %v", res[1].ConfidenceLevel)
	}
}

func TestPVMBGStore_ConfidenceStableAcrossReads(t *testing.T) {
	st := store.NewMemoryStore()
	conf := 0.91
	rep := models.VolcanicReport{
		ReportID:         "pvmbg-stable-001",
		VolcanoID:        "semeru",
		AlertLevel:       models.AlertLevelWaspada,
		EruptionCount24h: 3,
		AshColumnHeightM: 800.0,
		ReportedAt:       time.Now(),
		ConfidenceLevel:  &conf,
	}
	st.AddVolcanicReport(rep)

	results1 := st.GetVolcanicReports(time.Time{})
	results2 := st.GetVolcanicReports(time.Time{})

	if len(results1) != 1 || results1[0].ConfidenceLevel == nil {
		t.Fatal("expected non-nil confidence on initial read")
	}
	if len(results2) != 1 || results2[0].ConfidenceLevel == nil {
		t.Fatal("expected non-nil confidence on subsequent read")
	}
	if *results1[0].ConfidenceLevel != *results2[0].ConfidenceLevel {
		t.Fatalf("confidence not stable: %f vs %f", *results1[0].ConfidenceLevel, *results2[0].ConfidenceLevel)
	}
	if *results1[0].ConfidenceLevel != 0.91 {
		t.Fatalf("expected 0.91, got %f", *results1[0].ConfidenceLevel)
	}
}

