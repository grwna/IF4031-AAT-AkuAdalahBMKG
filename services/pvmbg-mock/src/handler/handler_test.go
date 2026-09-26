package handler_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/generator"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/handler"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/models"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/pvmbg-mock/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/shared/logger"
)

func setupPVMBGTestServer() (http.Handler, *handler.PVMBGHandler, *store.MemoryStore, string) {
	st := store.NewMemoryStore()
	generator.Seed(st, 5)
	log := logger.NewJSONLogger()
	token := "pvmbg-valid-token-xyz"

	h := handler.NewPVMBGHandler(st, token, 0, 0, log)
	return h.Routes(), h, st, token
}

func TestPVMBG_AuthRejection(t *testing.T) {
	router, _, _, _ := setupPVMBGTestServer()

	req := httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("expected 401 or 403 on missing auth, got %d", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")
	rec = httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusForbidden {
		t.Fatalf("expected 401 or 403 on invalid token, got %d", rec.Code)
	}
}

func TestPVMBG_SchemaEvolutionToggle(t *testing.T) {
	router, h, st, token := setupPVMBGTestServer()

	// Initial request: confidence_level should not appear
	req := httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", rec.Code)
	}

	var reports []models.VolcanicReport
	json.NewDecoder(rec.Body).Decode(&reports)
	for _, rep := range reports {
		if rep.ConfidenceLevel != nil {
			t.Fatalf("expected no confidence_level before schema upgrade")
		}
	}

	// Trigger schema evolution
	adminReq := httptest.NewRequest(http.MethodPost, "/admin/schema-version", bytes.NewBufferString(`{"enabled": true}`))
	adminReq.Header.Set("Authorization", "Bearer "+token)
	adminRec := httptest.NewRecorder()
	router.ServeHTTP(adminRec, adminReq)

	if adminRec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK on admin schema upgrade, got %d", adminRec.Code)
	}

	// Generate a report after schema evolution with current flag
	newRep := generator.GenerateVolcanicReport("pvmbg-post-upgrade", time.Now(), h.SchemaConfidence().Load())
	st.AddVolcanicReport(newRep)

	// Request reports after upgrade: coexistence of old and new records
	req2 := httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	req2.Header.Set("Authorization", "Bearer "+token)
	rec2 := httptest.NewRecorder()
	router.ServeHTTP(rec2, req2)

	var reports2 []models.VolcanicReport
	json.NewDecoder(rec2.Body).Decode(&reports2)

	// Historical records retain nil confidence_level
	for i := 0; i < 5; i++ {
		if reports2[i].ConfidenceLevel != nil {
			t.Fatalf("expected historical record %d to retain nil confidence_level", i)
		}
	}

	// Post-upgrade record has confidence_level
	if reports2[5].ConfidenceLevel == nil {
		t.Fatal("expected post-upgrade record to have confidence_level")
	}
}

func TestPVMBG_OutageSimulation(t *testing.T) {
	router, _, _, token := setupPVMBGTestServer()

	// Enable Outage
	adminReq := httptest.NewRequest(http.MethodPost, "/admin/outage", bytes.NewBufferString(`{"outage": true}`))
	adminReq.Header.Set("Authorization", "Bearer "+token)
	adminRec := httptest.NewRecorder()
	router.ServeHTTP(adminRec, adminReq)

	if adminRec.Code != http.StatusOK {
		t.Fatalf("expected 200 on setting outage, got %d", adminRec.Code)
	}

	// GET request during outage should return 503
	req := httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 Service Unavailable during outage, got %d", rec.Code)
	}

	// Disable Outage
	adminReq2 := httptest.NewRequest(http.MethodPost, "/admin/outage", bytes.NewBufferString(`{"outage": false}`))
	adminReq2.Header.Set("Authorization", "Bearer "+token)
	adminRec2 := httptest.NewRecorder()
	router.ServeHTTP(adminRec2, adminReq2)

	// GET request should succeed again
	req2 := httptest.NewRequest(http.MethodGet, "/volcanic-reports", nil)
	req2.Header.Set("Authorization", "Bearer "+token)
	rec2 := httptest.NewRecorder()
	router.ServeHTTP(rec2, req2)

	if rec2.Code != http.StatusOK {
		t.Fatalf("expected 200 OK after outage restored, got %d", rec2.Code)
	}
}
