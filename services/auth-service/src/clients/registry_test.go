package clients_test

import (
	"testing"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/clients"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
)

func newTestRegistry(t *testing.T) *clients.Registry {
	t.Helper()
	r, err := clients.NewRegistry([]config.ClientConfig{
		{ID: "media-client", Secret: "media-secret", Scope: "hazards:read:summary"},
		{ID: "field-team", Secret: "field-secret", Scope: "hazards:read:raw"},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	return r
}

func TestAuthenticate_Valid(t *testing.T) {
	r := newTestRegistry(t)

	c, ok := r.Authenticate("field-team", "field-secret")
	if !ok {
		t.Fatal("expected valid credentials to authenticate")
	}
	if c.ID != "field-team" || c.Scope != "hazards:read:raw" {
		t.Errorf("unexpected client: %+v", c)
	}
}

func TestAuthenticate_WrongSecret(t *testing.T) {
	r := newTestRegistry(t)

	if _, ok := r.Authenticate("field-team", "media-secret"); ok {
		t.Fatal("expected wrong secret to be rejected")
	}
}

func TestAuthenticate_UnknownClient(t *testing.T) {
	r := newTestRegistry(t)

	if _, ok := r.Authenticate("unknown", "dummy-secret"); ok {
		t.Fatal("expected unknown client to be rejected")
	}
}

func TestNewRegistry_DuplicateID(t *testing.T) {
	_, err := clients.NewRegistry([]config.ClientConfig{
		{ID: "dup", Secret: "a", Scope: "x"},
		{ID: "dup", Secret: "b", Scope: "y"},
	})
	if err == nil {
		t.Fatal("expected error for duplicate client id")
	}
}
