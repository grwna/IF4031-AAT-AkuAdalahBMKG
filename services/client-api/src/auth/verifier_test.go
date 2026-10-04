package auth_test

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

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/client-api/src/auth"
)

const (
	testIssuer   = "bnpb-auth-service"
	testAudience = "bnpb-client-api"
)

func newKeyPair(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func validClaims() auth.Claims {
	now := time.Now()
	return auth.Claims{
		Scope: "hazards:read:raw",
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    testIssuer,
			Audience:  jwt.ClaimStrings{testAudience},
			Subject:   "field-team",
			ID:        "jti-1",
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Minute)),
		},
	}
}

func sign(t *testing.T, priv ed25519.PrivateKey, c auth.Claims) string {
	t.Helper()
	s, err := jwt.NewWithClaims(jwt.SigningMethodEdDSA, c).SignedString(priv)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestParsePublicKey(t *testing.T) {
	pub, _ := newKeyPair(t)
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.StdEncoding.EncodeToString(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))

	got, err := auth.ParsePublicKey(b64)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Equal(pub) {
		t.Error("parsed key does not match original")
	}
}

func TestParsePublicKey_Invalid(t *testing.T) {
	for name, in := range map[string]string{
		"not base64":   "%%%",
		"not pem":      base64.StdEncoding.EncodeToString([]byte("hello")),
		"empty string": "",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := auth.ParsePublicKey(in); err == nil {
				t.Error("expected error")
			}
		})
	}
}

func TestVerify_Valid(t *testing.T) {
	pub, priv := newKeyPair(t)
	v := auth.NewVerifier(pub, testIssuer, testAudience, 0)

	claims, err := v.Verify(sign(t, priv, validClaims()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if claims.Subject != "field-team" || claims.Scope != "hazards:read:raw" || claims.ID != "jti-1" {
		t.Errorf("unexpected claims: %+v", claims)
	}
}

func TestVerify_Expired(t *testing.T) {
	pub, priv := newKeyPair(t)
	v := auth.NewVerifier(pub, testIssuer, testAudience, 0)

	c := validClaims()
	c.IssuedAt = jwt.NewNumericDate(time.Now().Add(-2 * time.Minute))
	c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute))

	_, err := v.Verify(sign(t, priv, c))
	if !errors.Is(err, auth.ErrTokenExpired) {
		t.Fatalf("expected ErrTokenExpired, got %v", err)
	}
}

func TestVerify_LeewayAcceptsRecentlyExpired(t *testing.T) {
	pub, priv := newKeyPair(t)
	v := auth.NewVerifier(pub, testIssuer, testAudience, 10*time.Second)

	c := validClaims()
	c.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-3 * time.Second))

	if _, err := v.Verify(sign(t, priv, c)); err != nil {
		t.Fatalf("expected token within leeway to pass, got %v", err)
	}
}

func TestVerify_Rejected(t *testing.T) {
	pub, priv := newKeyPair(t)
	_, otherPriv := newKeyPair(t)
	v := auth.NewVerifier(pub, testIssuer, testAudience, 0)

	expiredOtherKey := validClaims()
	expiredOtherKey.ExpiresAt = jwt.NewNumericDate(time.Now().Add(-time.Minute))

	wrongIssuer := validClaims()
	wrongIssuer.Issuer = "someone-else"

	wrongAudience := validClaims()
	wrongAudience.Audience = jwt.ClaimStrings{"other-api"}

	noExp := validClaims()
	noExp.ExpiresAt = nil

	hs256, err := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims()).SignedString([]byte(pub))
	if err != nil {
		t.Fatal(err)
	}
	none, err := jwt.NewWithClaims(jwt.SigningMethodNone, validClaims()).SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatal(err)
	}

	cases := map[string]string{
		"signed by other key":         sign(t, otherPriv, validClaims()),
		"expired and signed by other": sign(t, otherPriv, expiredOtherKey),
		"wrong issuer":                sign(t, priv, wrongIssuer),
		"wrong audience":              sign(t, priv, wrongAudience),
		"missing exp":                 sign(t, priv, noExp),
		"alg HS256 with public key":   hs256,
		"alg none":                    none,
		"garbage":                     "not.a.jwt",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := v.Verify(raw)
			if !errors.Is(err, auth.ErrInvalidToken) {
				t.Fatalf("expected ErrInvalidToken, got %v", err)
			}
		})
	}
}

func TestClaims_HasScope(t *testing.T) {
	c := auth.Claims{Scope: "hazards:read:summary hazards:read:raw"}
	if !c.HasScope("hazards:read:summary") || !c.HasScope("hazards:read:raw") {

		t.Error("expected both scopes present")
	}
	if c.HasScope("hazards:read") || c.HasScope("hazards") {
		t.Error("expected partial scope to be false")
	}
	single := auth.Claims{Scope: "hazards:read:raw"}
	if single.HasScope("hazards:read:summary") {
		t.Error("expected absent scope to be false")
	}
}
