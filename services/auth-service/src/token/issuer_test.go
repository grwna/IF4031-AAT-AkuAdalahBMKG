package token

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testIssuer   = "bnpb-auth-service"
	testAudience = "bnpb-client-api"
)

func generateKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return pub, priv
}

func parse(t *testing.T, signed string, pub ed25519.PublicKey) (*Claims, error) {
	t.Helper()
	claims := &Claims{}
	_, err := jwt.ParseWithClaims(signed, claims,
		func(*jwt.Token) (any, error) { return pub, nil },
		jwt.WithValidMethods([]string{"EdDSA"}),
		jwt.WithIssuer(testIssuer),
		jwt.WithAudience(testAudience),
	)
	return claims, err
}

func TestParsePrivateKey(t *testing.T) {
	_, priv := generateKey(t)
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	b64 := base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))

	parsed, err := ParsePrivateKey(b64)
	if err != nil {
		t.Fatalf("ParsePrivateKey: %v", err)
	}
	if !parsed.Equal(priv) {
		t.Fatal("parsed key does not match original")
	}

	if _, err := ParsePrivateKey("not-base64!!"); err == nil {
		t.Fatal("expected error for invalid input")
	}
}

func TestIssue_VerifiableWithClaims(t *testing.T) {
	pub, priv := generateKey(t)
	issuer := NewIssuer(priv, testIssuer, testAudience, 60*time.Second)

	signed, jti, err := issuer.Issue("field-team", "hazards:read:raw")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	claims, err := parse(t, signed, pub)
	if err != nil {
		t.Fatalf("token should verify: %v", err)
	}
	if claims.Subject != "field-team" {
		t.Errorf("sub = %q", claims.Subject)
	}
	if claims.Scope != "hazards:read:raw" {
		t.Errorf("scope = %q", claims.Scope)
	}
	if claims.ID != jti {
		t.Errorf("jti = %q, want %q", claims.ID, jti)
	}
	if ttl := claims.ExpiresAt.Sub(claims.IssuedAt.Time); ttl != 60*time.Second {
		t.Errorf("exp - iat = %v, want 60s", ttl)
	}
}

func TestIssue_RejectedByOtherKey(t *testing.T) {
	_, priv := generateKey(t)
	otherPub, _ := generateKey(t)
	issuer := NewIssuer(priv, testIssuer, testAudience, time.Minute)

	signed, _, err := issuer.Issue("field-team", "hazards:read:raw")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if _, err := parse(t, signed, otherPub); !errors.Is(err, jwt.ErrTokenSignatureInvalid) {
		t.Fatalf("expected signature error, got %v", err)
	}
}

func TestIssue_ExpiredRejected(t *testing.T) {
	pub, priv := generateKey(t)
	issuer := NewIssuer(priv, testIssuer, testAudience, 60*time.Second)
	issuer.now = func() time.Time { return time.Now().Add(-2 * time.Minute) }

	signed, _, err := issuer.Issue("field-team", "hazards:read:raw")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if _, err := parse(t, signed, pub); !errors.Is(err, jwt.ErrTokenExpired) {
		t.Fatalf("expected expired error, got %v", err)
	}
}

func TestIssue_WrongAudienceRejected(t *testing.T) {
	pub, priv := generateKey(t)
	issuer := NewIssuer(priv, testIssuer, "pemda-portal", time.Minute)

	signed, _, err := issuer.Issue("pemda", "hazards:read:raw")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	if _, err := parse(t, signed, pub); !errors.Is(err, jwt.ErrTokenInvalidAudience) {
		t.Fatalf("expected audience error, got %v", err)
	}
}

func TestRefreshToken_UniqueAndHashed(t *testing.T) {
	a, err := NewRefreshToken()
	if err != nil {
		t.Fatalf("NewRefreshToken: %v", err)
	}
	b, _ := NewRefreshToken()

	if a == b {
		t.Fatal("refresh tokens should be unique")
	}
	h1, h2 := HashRefreshToken(a), HashRefreshToken(a)
	if h1 != h2 {
		t.Fatal("hash should be deterministic")
	}
	if h1 == a {
		t.Fatal("hash should differ from token")
	}
}
