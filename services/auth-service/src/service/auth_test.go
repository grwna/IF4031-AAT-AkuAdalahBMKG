package service_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/clients"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/config"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/service"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/token"
)

type fixture struct {
	svc *service.AuthService
	pub ed25519.PublicKey
	mr  *miniredis.Miniredis
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	mr := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { client.Close() })
	st := store.NewRedisStore(client)

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	registry, err := clients.NewRegistry([]config.ClientConfig{
		{ID: "field-team", Secret: "field-secret", Scope: "hazards:read:raw"},
		{ID: "media-client", Secret: "media-secret", Scope: "hazards:read:summary"},
	})
	if err != nil {
		t.Fatalf("registry: %v", err)
	}
	issuer := token.NewIssuer(priv, "bnpb-auth-service", "bnpb-client-api", time.Minute)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return fixture{svc: service.New(registry, issuer, st, time.Hour, log), pub: pub, mr: mr}
}

func (f fixture) login(t *testing.T) service.TokenPair {
	t.Helper()
	pair, err := f.svc.IssueToken(context.Background(), "field-team", "field-secret")
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	return pair
}

func (f fixture) claims(t *testing.T, access string) *token.Claims {
	t.Helper()
	c := &token.Claims{}
	_, err := jwt.ParseWithClaims(access, c,
		func(*jwt.Token) (any, error) { return f.pub, nil },
		jwt.WithValidMethods([]string{"EdDSA"}),
	)
	if err != nil {
		t.Fatalf("access token invalid: %v", err)
	}
	return c
}

func TestIssueToken_Valid(t *testing.T) {
	f := newFixture(t)

	pair := f.login(t)

	c := f.claims(t, pair.AccessToken)
	if c.Subject != "field-team" || c.Scope != "hazards:read:raw" {
		t.Errorf("unexpected claims: sub=%q scope=%q", c.Subject, c.Scope)
	}
	if pair.RefreshToken == "" || pair.AccessTTL != time.Minute || pair.RefreshTTL != time.Hour {
		t.Errorf("unexpected pair: %+v", pair)
	}
}

func TestIssueToken_InvalidClient(t *testing.T) {
	f := newFixture(t)

	_, err := f.svc.IssueToken(context.Background(), "field-team", "wrong")
	if !errors.Is(err, service.ErrInvalidClient) {
		t.Fatalf("expected ErrInvalidClient, got %v", err)
	}
}

func TestRefresh_RotatesTokens(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	first := f.login(t)

	second, err := f.svc.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if second.RefreshToken == first.RefreshToken || second.AccessToken == first.AccessToken {
		t.Fatal("refresh should return new tokens")
	}
	if c := f.claims(t, second.AccessToken); c.Subject != "field-team" || c.Scope != "hazards:read:raw" {
		t.Errorf("refreshed claims: sub=%q scope=%q", c.Subject, c.Scope)
	}

	third, err := f.svc.Refresh(ctx, second.RefreshToken)
	if err != nil {
		t.Fatalf("second Refresh with new token: %v", err)
	}
	if third.RefreshToken == second.RefreshToken {
		t.Fatal("each refresh should rotate the token")
	}
}

func TestRefresh_ReuseRevokesFamily(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	r1 := f.login(t).RefreshToken

	second, err := f.svc.Refresh(ctx, r1)
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}

	if _, err := f.svc.Refresh(ctx, r1); !errors.Is(err, service.ErrInvalidGrant) {
		t.Fatalf("reusing old token: expected ErrInvalidGrant, got %v", err)
	}
	if _, err := f.svc.Refresh(ctx, second.RefreshToken); !errors.Is(err, service.ErrInvalidGrant) {
		t.Fatalf("token from revoked family: expected ErrInvalidGrant, got %v", err)
	}
}

func TestRefresh_OtherFamilyUnaffectedByReuse(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	sessionA := f.login(t).RefreshToken
	sessionB := f.login(t).RefreshToken

	_, _ = f.svc.Refresh(ctx, sessionA)
	_, _ = f.svc.Refresh(ctx, sessionA)

	if _, err := f.svc.Refresh(ctx, sessionB); err != nil {
		t.Fatalf("other session should still work: %v", err)
	}
}

func TestRefresh_UnknownToken(t *testing.T) {
	f := newFixture(t)

	if _, err := f.svc.Refresh(context.Background(), "not-a-real-token"); !errors.Is(err, service.ErrInvalidGrant) {
		t.Fatalf("expected ErrInvalidGrant, got %v", err)
	}
}

func TestRefresh_Expired(t *testing.T) {
	f := newFixture(t)
	r1 := f.login(t).RefreshToken

	f.mr.FastForward(2 * time.Hour)

	if _, err := f.svc.Refresh(context.Background(), r1); !errors.Is(err, service.ErrInvalidGrant) {
		t.Fatalf("expected ErrInvalidGrant for expired token, got %v", err)
	}
}

func TestRefresh_ConcurrentOnlyOneWins(t *testing.T) {
	f := newFixture(t)
	r1 := f.login(t).RefreshToken

	var wins atomic.Int32
	var wg sync.WaitGroup
	for range 10 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.svc.Refresh(context.Background(), r1); err == nil {
				wins.Add(1)
			}
		}()
	}
	wg.Wait()

	if wins.Load() != 1 {
		t.Fatalf("expected exactly 1 successful refresh, got %d", wins.Load())
	}
}

func TestRefresh_StoreErrorIsNotInvalidGrant(t *testing.T) {
	f := newFixture(t)
	f.mr.Close()

	_, err := f.svc.Refresh(context.Background(), "anything")
	if err == nil || errors.Is(err, service.ErrInvalidGrant) {
		t.Fatalf("store failure should surface as internal error, got %v", err)
	}
}

func TestIssueToken_StoreErrorIsNotInvalidClient(t *testing.T) {
	f := newFixture(t)
	f.mr.Close()

	_, err := f.svc.IssueToken(context.Background(), "field-team", "field-secret")
	if err == nil || errors.Is(err, service.ErrInvalidClient) {
		t.Fatalf("store failure should surface as internal error, got %v", err)
	}
}
