package generator

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/bmkg-mock/src/store"
)

var regions = []string{
	"Barat Daya Sumur, Banten",
	"Selatan Malang, Jawa Timur",
	"Tenggara Luwu Timur, Sulawesi Selatan",
	"Barat Laut Jayapura, Papua",
	"Barat Daya Meulaboh, Aceh",
	"Samudera Hindia Selatan Jawa",
	"Pesisir Barat Sumatera",
	"Laut Banda, Maluku",
}

var threatLevels = []models.ThreatLevel{
	models.ThreatLevelWaspada,
	models.ThreatLevelSiaga,
	models.ThreatLevelAwas,
}

var affectedZones = []string{
	"Pesisir Selatan",
	"Kepulauan Mentawai",
	"Pesisir Barat Lampung",
	"Pesisir Selatan Jawa",
	"Bali & Lombok",
}

func GenerateSeismicEvent(eventID, warningID string, eventTime time.Time) (models.SeismicEvent, *models.TsunamiWarning) {
	mag := 3.5 + rand.Float64()*4.5
	magRounded := float64(int(mag*10)) / 10.0
	hasTsunami := magRounded >= 6.8

	ev := models.SeismicEvent{
		EventID:          eventID,
		Magnitude:        magRounded,
		DepthKM:          5.0 + float64(rand.Intn(120)),
		EpicenterLat:     -11.0 + rand.Float64()*17.0,
		EpicenterLon:     95.0 + rand.Float64()*45.0,
		RegionName:       regions[rand.Intn(len(regions))],
		OccurredAt:       eventTime,
		PotentialTsunami: hasTsunami,
	}

	var warn *models.TsunamiWarning
	if hasTsunami {
		level := threatLevels[rand.Intn(len(threatLevels))]
		if magRounded >= 7.5 {
			level = models.ThreatLevelAwas
		}

		zones := []string{affectedZones[rand.Intn(len(affectedZones))]}
		warn = &models.TsunamiWarning{
			WarningID:        warningID,
			RelatedEventID:   eventID,
			ThreatLevel:      level,
			AffectedZones:    zones,
			EstimatedArrival: eventTime.Add(time.Duration(15+rand.Intn(45)) * time.Minute),
		}
	}

	return ev, warn
}

func Seed(st *store.MemoryStore, count int) {
	baseTime := time.Now().Add(-time.Duration(count*15) * time.Minute)
	for i := 0; i < count; i++ {
		eventTime := baseTime.Add(time.Duration(i*15) * time.Minute)
		eventID := fmt.Sprintf("seismic-%04d", i+1)
		warningID := fmt.Sprintf("tsunami-%04d", i+1)

		ev, warn := GenerateSeismicEvent(eventID, warningID, eventTime)
		st.AddSeismicEvent(ev, warn)
	}
}

func Start(ctx context.Context, st *store.MemoryStore, interval time.Duration, log *slog.Logger) {
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
				eventID := fmt.Sprintf("seismic-%04d", counter)
				warningID := fmt.Sprintf("tsunami-%04d", counter)

				ev, warn := GenerateSeismicEvent(eventID, warningID, now)
				st.AddSeismicEvent(ev, warn)
				log.Info("generated new seismic event", "event_id", eventID, "magnitude", ev.Magnitude, "potential_tsunami", ev.PotentialTsunami)
			}
		}
	}()
}
