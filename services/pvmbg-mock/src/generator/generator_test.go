package generator_test

import (
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/generator"
)

func TestGenerateVolcanicReport(t *testing.T) {
	now := time.Now()
	repWithout := generator.GenerateVolcanicReport("rep-1", now, false)

	if repWithout.ReportID != "rep-1" {
		t.Fatalf("expected report ID rep-1, got %s", repWithout.ReportID)
	}
	if repWithout.VolcanoID == "" {
		t.Fatal("expected volcano ID to be set")
	}
	if repWithout.AlertLevel == "" {
		t.Fatal("expected alert level to be set")
	}
	if repWithout.ConfidenceLevel != nil {
		t.Fatal("expected confidence level to be nil when includeConfidence is false")
	}

	repWith := generator.GenerateVolcanicReport("rep-2", now, true)
	if repWith.ConfidenceLevel == nil {
		t.Fatal("expected confidence level to be non-nil when includeConfidence is true")
	}
}
