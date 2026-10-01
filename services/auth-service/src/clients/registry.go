package clients

import (
	"crypto/sha256"
	"crypto/subtle"
	"fmt"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
)

type Client struct {
	ID    string
	Scope string
}

type entry struct {
	client     Client
	secretHash [32]byte
}

type Registry struct {
	clients map[string]entry
	dummy   [32]byte
}

func NewRegistry(cfgs []config.ClientConfig) (*Registry, error) {
	r := &Registry{
		clients: make(map[string]entry, len(cfgs)),
		dummy:   sha256.Sum256([]byte("dummy-secret")),
	}
	for _, c := range cfgs {
		if _, exists := r.clients[c.ID]; exists {
			return nil, fmt.Errorf("duplicate client id %q", c.ID)
		}
		r.clients[c.ID] = entry{
			client:     Client{ID: c.ID, Scope: c.Scope},
			secretHash: sha256.Sum256([]byte(c.Secret)),
		}
	}
	return r, nil
}

func (r *Registry) Lookup(id string) (Client, bool) {
	e, ok := r.clients[id]
	return e.client, ok
}

func (r *Registry) Authenticate(id, secret string) (Client, bool) {
	given := sha256.Sum256([]byte(secret))

	e, found := r.clients[id]
	expected := r.dummy
	if found {
		expected = e.secretHash
	}

	match := subtle.ConstantTimeCompare(given[:], expected[:]) == 1
	if !found || !match {
		return Client{}, false
	}
	return e.client, true
}
