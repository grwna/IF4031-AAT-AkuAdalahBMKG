package generator

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"sync/atomic"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/store"
)

var volcanoes = []string{
	"Merapi",
	"Sinabung",
	"Semeru",
	"Krakatau",
	"Marapi",
	"Lewotobi",
}

var levels = []models.AlertLevel{
	models.AlertLevelNormal,
	models.AlertLevelWaspada,
	models.AlertLevelSiaga,
	models.AlertLevelAwas,
}

func GenerateVolcanicReport(reportID string, reportTime time.Time, includeConfidence bool) models.VolcanicReport {
	var conf *float64
	if includeConfidence {
		val := float64(int((0.70+rand.Float64()*0.28)*100)) / 100.0
		conf = &val
	}

	return models.VolcanicReport{
		ReportID:         reportID,
		VolcanoID:        volcanoes[rand.Intn(len(volcanoes))],
		AlertLevel:       levels[rand.Intn(len(levels))],
		EruptionCount24h: rand.Intn(30),
		AshColumnHeightM: float64(100 + rand.Intn(4000)),
		ReportedAt:       reportTime,
		ConfidenceLevel:  conf,
	}
}

func Seed(st *store.MemoryStore, count int) {
	baseTime := time.Now().Add(-time.Duration(count*20) * time.Minute)
	for i := 0; i < count; i++ {
		reportTime := baseTime.Add(time.Duration(i*20) * time.Minute)
		reportID := fmt.Sprintf("pvmbg-%04d", i+1)

		rep := GenerateVolcanicReport(reportID, reportTime, false)
		st.AddVolcanicReport(rep)
	}
}

func Start(ctx context.Context, st *store.MemoryStore, schemaConfidence *atomic.Bool, interval time.Duration, log *slog.Logger) {
	ticker := time.NewTicker(interval)
	go func() {
		counter := 20 // default seed amount
		for {
			select {
			case <-ctx.Done():
				ticker.Stop()
				return
			case <-ticker.C:
				counter++
				now := time.Now()
				reportID := fmt.Sprintf("pvmbg-%04d", counter)

				includeConf := schemaConfidence != nil && schemaConfidence.Load()
				rep := GenerateVolcanicReport(reportID, now, includeConf)
				st.AddVolcanicReport(rep)
				log.Info("generated new volcanic report", "report_id", rep.ReportID, "volcano_id", rep.VolcanoID, "alert_level", rep.AlertLevel)
			}
		}
	}()
}
