package polling

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/mapping"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/store"
)

// Tracker thread-safe untuk memantau status kesegaran data per sumber (BMKG & PVMBG)
type StatusTracker struct {
	mu     sync.RWMutex
	status domain.MapSourceStatus
}

func NewStatusTracker() *StatusTracker {
	return &StatusTracker{
		status: domain.MapSourceStatus{
			domain.SourceBMKG:  {Status: domain.SourceStatusUp},
			domain.SourcePVMBG: {Status: domain.SourceStatusUp},
		},
	}
}

func (t *StatusTracker) GetStatus() domain.MapSourceStatus {
	t.mu.RLock()
	defer t.mu.RUnlock()

	// Deep copy map untuk menghindari race condition saat dibaca HTTP handler
	cp := make(domain.MapSourceStatus)
	for k, v := range t.status {
		cp[k] = v
	}
	return cp
}

func (t *StatusTracker) SetSuccess(source string, now time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()

	st := t.status[source]
	st.Status = domain.SourceStatusUp
	st.LastSuccessAt = &now
	st.StaleSince = nil
	st.LastError = nil
	t.status[source] = st
}

func (t *StatusTracker) SetDegraded(source string, now time.Time, errStr string) {
	t.mu.Lock()
	defer t.mu.Unlock()

	st := t.status[source]
	st.Status = domain.SourceStatusDegraded
	if st.StaleSince == nil {
		if st.LastSuccessAt != nil {
			st.StaleSince = st.LastSuccessAt
		} else {
			st.StaleSince = &now
		}
	}
	st.LastError = &errStr
	t.status[source] = st
}

// Struct Poller yang menjalankan loop polling ke BMKG dan PVMBG
type Poller struct {
	store        *store.PostgresStore
	tracker      *StatusTracker
	logger       *slog.Logger
	bmkgURL      string
	bmkgKey      string
	pvmbgURL     string
	pvmbgToken   string
	pollInterval time.Duration
	httpClient   *http.Client
}

func NewPoller(
	store *store.PostgresStore,
	tracker *StatusTracker,
	logger *slog.Logger,
	bmkgURL, bmkgKey, pvmbgURL, pvmbgToken string,
	pollInterval time.Duration,
) *Poller {
	return &Poller{
		store:        store,
		tracker:      tracker,
		logger:       logger,
		bmkgURL:      bmkgURL,
		bmkgKey:      bmkgKey,
		pvmbgURL:     pvmbgURL,
		pvmbgToken:   pvmbgToken,
		pollInterval: pollInterval,
		httpClient: &http.Client{
			Timeout: 5 * time.Second, // Timeout aman untuk polling
		},
	}
}

// Start menjalankan goroutine polling berkala hingga context dibatalkan
func (p *Poller) Start(ctx context.Context) {
	p.logger.Info("Memulai background poller untuk BMKG dan PVMBG", slog.Duration("interval", p.pollInterval))
	ticker := time.NewTicker(p.pollInterval)
	defer ticker.Stop()

	// Jalankan polling pertama kali langsung saat start
	p.pollBMKG(ctx)
	p.pollPVMBG(ctx)

	for {
		select {
		case <-ctx.Done():
			p.logger.Info("Background poller dihentikan")
			return
		case <-ticker.C:
			// Polling dilakukan secara independen agar kelambatan PVMBG tidak menahan BMKG
			go p.pollBMKG(ctx)
			go p.pollPVMBG(ctx)
		}
	}
}

// Polling data seismik dan tsunami dari BMKG
func (p *Poller) pollBMKG(ctx context.Context) {
	now := time.Now().UTC()
	// Polling seismic events (mengambil data historis/terbaru)
	reqURL := fmt.Sprintf("%s/seismic-events", p.bmkgURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		p.tracker.SetDegraded(domain.SourceBMKG, now, err.Error())
		return
	}
	req.Header.Set("X-BMKG-Key", p.bmkgKey)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		p.logger.Warn("Polling BMKG gagal", slog.String("error", err.Error()))
		p.tracker.SetDegraded(domain.SourceBMKG, now, err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errStr := fmt.Sprintf("HTTP %d dari BMKG", resp.StatusCode)
		p.logger.Warn("Polling BMKG mengembalikan status non-200", slog.Int("status", resp.StatusCode))
		p.tracker.SetDegraded(domain.SourceBMKG, now, errStr)
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		p.tracker.SetDegraded(domain.SourceBMKG, now, err.Error())
		return
	}

	var events []domain.SeismicEvent
	if err := json.Unmarshal(body, &events); err != nil {
		p.logger.Error("Gagal unmarshal data BMKG", slog.String("error", err.Error()))
		p.tracker.SetDegraded(domain.SourceBMKG, now, "JSON decode error")
		return
	}

	// Ambil TsunamiWarnings jika ada event yang memiliki potential_tsunami=true
	hasPotentialTsunami := false
	for _, e := range events {
		if e.PotentialTsunami {
			hasPotentialTsunami = true
			break
		}
	}

	tsunamiMap := make(map[string]*domain.TsunamiWarning)
	if hasPotentialTsunami {
		tURL := fmt.Sprintf("%s/tsunami-warnings", p.bmkgURL)
		tReq, err := http.NewRequestWithContext(ctx, http.MethodGet, tURL, nil)
		if err == nil {
			tReq.Header.Set("X-BMKG-Key", p.bmkgKey)
			if tResp, err := p.httpClient.Do(tReq); err == nil && tResp.StatusCode == http.StatusOK {
				defer tResp.Body.Close()
				var warnings []domain.TsunamiWarning
				if tBody, err := io.ReadAll(tResp.Body); err == nil {
					if json.Unmarshal(tBody, &warnings) == nil {
						for i := range warnings {
							tsunamiMap[warnings[i].RelatedEventID] = &warnings[i]
						}
					}
				}
			}
		}
	}

	// Simpan/update setiap event ke Canonical Store
	ingestedAt := time.Now().UTC()
	for _, e := range events {
		warning := tsunamiMap[e.EventID]
		kanonik := mapping.MapSeismicToHazard(e, warning, ingestedAt)
		if err := p.store.UpsertHazardEvent(ctx, kanonik); err != nil {
			p.logger.Error("Gagal upsert event BMKG ke store", slog.String("hazard_id", kanonik.HazardID), slog.String("error", err.Error()))
		}
	}

	p.tracker.SetSuccess(domain.SourceBMKG, now)
}

// Polling laporan gunung api dari PVMBG
func (p *Poller) pollPVMBG(ctx context.Context) {
	now := time.Now().UTC()
	reqURL := fmt.Sprintf("%s/volcanic-reports", p.pvmbgURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		p.tracker.SetDegraded(domain.SourcePVMBG, now, err.Error())
		return
	}
	req.Header.Set("Authorization", "Bearer "+p.pvmbgToken)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		p.logger.Warn("Polling PVMBG gagal (outage/network error)", slog.String("error", err.Error()))
		p.tracker.SetDegraded(domain.SourcePVMBG, now, err.Error())
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		errStr := fmt.Sprintf("%d from pvmbg", resp.StatusCode)
		p.logger.Warn("Polling PVMBG mengembalikan status non-200", slog.Int("status", resp.StatusCode))
		p.tracker.SetDegraded(domain.SourcePVMBG, now, errStr)
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		p.tracker.SetDegraded(domain.SourcePVMBG, now, err.Error())
		return
	}

	var reports []domain.VolcanicReport
	if err := json.Unmarshal(body, &reports); err != nil {
		p.logger.Error("Gagal unmarshal data PVMBG", slog.String("error", err.Error()))
		p.tracker.SetDegraded(domain.SourcePVMBG, now, "JSON decode error")
		return
	}

	// Simpan/update setiap laporan ke Canonical Store
	ingestedAt := time.Now().UTC()
	for _, r := range reports {
		kanonik := mapping.MapVolcanicToHazard(r, ingestedAt)
		if err := p.store.UpsertHazardEvent(ctx, kanonik); err != nil {
			p.logger.Error("Gagal upsert event PVMBG ke store", slog.String("hazard_id", kanonik.HazardID), slog.String("error", err.Error()))
		}
	}

	p.tracker.SetSuccess(domain.SourcePVMBG, now)
}
