package auth

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	ErrInvalidToken = errors.New("invalid token")
	ErrTokenExpired = errors.New("token expired")
)

type Claims struct {
	Scope string `json:"scope"`
	jwt.RegisteredClaims
}

func (c *Claims) HasScope(scope string) bool {
	return slices.Contains(strings.Fields(c.Scope), scope)
}

type Verifier struct {
	key    ed25519.PublicKey
	parser *jwt.Parser
}

func ParsePublicKey(b64 string) (ed25519.PublicKey, error) {
	pemBytes, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("decode base64: %w", err)
	}
	key, err := jwt.ParseEdPublicKeyFromPEM(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("parse PEM: %w", err)
	}
	edKey, ok := key.(ed25519.PublicKey)
	if !ok {
		return nil, fmt.Errorf("key is not Ed25519")
	}
	return edKey, nil
}

func NewVerifier(key ed25519.PublicKey, issuer, audience string, leeway time.Duration) *Verifier {
	return &Verifier{
		key: key,
		parser: jwt.NewParser(
			jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
			jwt.WithIssuer(issuer),
			jwt.WithAudience(audience),
			jwt.WithExpirationRequired(),
			jwt.WithLeeway(leeway),
		),
	}
}

func (v *Verifier) Verify(raw string) (*Claims, error) {
	claims := &Claims{}
	_, err := v.parser.ParseWithClaims(raw, claims, func(*jwt.Token) (any, error) {
		return v.key, nil
	})
	if err == nil {
		return claims, nil
	}
	if errors.Is(err, jwt.ErrTokenExpired) && !errors.Is(err, jwt.ErrTokenSignatureInvalid) {
		return nil, fmt.Errorf("%w: %v", ErrTokenExpired, err)
	}
	return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
}
