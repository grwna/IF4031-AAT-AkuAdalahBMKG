package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/clients"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/store"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/token"
)

var (
	ErrInvalidClient = errors.New("invalid client credentials")
	ErrInvalidGrant  = errors.New("invalid refresh token")
	ErrUnavailable   = errors.New("token store unavailable")
)

type TokenPair struct {
	AccessToken  string
	AccessTTL    time.Duration
	RefreshToken string
	RefreshTTL   time.Duration
	Scope        string
}

type AuthService struct {
	registry   *clients.Registry
	issuer     *token.Issuer
	store      *store.RedisStore
	refreshTTL time.Duration
	log        *slog.Logger
}

func New(registry *clients.Registry, issuer *token.Issuer, st *store.RedisStore, refreshTTL time.Duration, log *slog.Logger) *AuthService {
	return &AuthService{
		registry:   registry,
		issuer:     issuer,
		store:      st,
		refreshTTL: refreshTTL,
		log:        log,
	}
}

func (s *AuthService) Ping(ctx context.Context) error {
	return s.store.Ping(ctx)
}

func (s *AuthService) IssueToken(ctx context.Context, clientID, secret string) (TokenPair, error) {
	client, ok := s.registry.Authenticate(clientID, secret)
	if !ok {
		s.log.WarnContext(ctx, "invalid_client", "client_id", clientID)
		return TokenPair{}, ErrInvalidClient
	}

	familyID, err := token.NewID()
	if err != nil {
		return TokenPair{}, err
	}

	pair, jti, err := s.issuePair(ctx, client, familyID)
	if err != nil {
		return TokenPair{}, err
	}
	s.log.InfoContext(ctx, "token_issued", "client_id", client.ID, "scope", client.Scope, "jti", jti, "family_id", familyID)
	return pair, nil
}

func (s *AuthService) Refresh(ctx context.Context, refreshToken string) (TokenPair, error) {
	hash := token.HashRefreshToken(refreshToken)

	rec, ok, err := s.store.Consume(ctx, hash)
	if err != nil {
		return TokenPair{}, unavailable("consume refresh token", err)
	}
	if !ok {
		return TokenPair{}, s.rejectUnknown(ctx, hash)
	}

	revoked, err := s.store.IsFamilyRevoked(ctx, rec.FamilyID)
	if err != nil {
		return TokenPair{}, unavailable("check family", err)
	}
	if revoked {
		s.log.WarnContext(ctx, "refresh_rejected", "reason", "revoked_family", "client_id", rec.ClientID, "family_id", rec.FamilyID)
		return TokenPair{}, ErrInvalidGrant
	}

	client, ok := s.registry.Lookup(rec.ClientID)
	if !ok {
		s.log.WarnContext(ctx, "refresh_rejected", "reason", "unknown_client", "client_id", rec.ClientID)
		return TokenPair{}, ErrInvalidGrant
	}

	if err := s.store.MarkUsed(ctx, hash, rec.FamilyID, s.refreshTTL); err != nil {
		return TokenPair{}, unavailable("mark used", err)
	}

	pair, jti, err := s.issuePair(ctx, client, rec.FamilyID)
	if err != nil {
		return TokenPair{}, err
	}
	s.log.InfoContext(ctx, "token_refreshed", "client_id", client.ID, "jti", jti, "family_id", rec.FamilyID)
	return pair, nil
}

func (s *AuthService) rejectUnknown(ctx context.Context, hash string) error {
	familyID, used, err := s.store.UsedFamily(ctx, hash)
	if err != nil {
		return unavailable("check used", err)
	}
	if !used {
		s.log.WarnContext(ctx, "refresh_rejected", "reason", "unknown")
		return ErrInvalidGrant
	}

	if err := s.store.RevokeFamily(ctx, familyID, s.refreshTTL); err != nil {
		return unavailable("revoke family", err)
	}
	s.log.WarnContext(ctx, "refresh_reuse_detected", "family_id", familyID)
	return ErrInvalidGrant
}

func (s *AuthService) issuePair(ctx context.Context, client clients.Client, familyID string) (TokenPair, string, error) {
	refresh, err := token.NewRefreshToken()
	if err != nil {
		return TokenPair{}, "", err
	}
	rec := store.RefreshRecord{ClientID: client.ID, FamilyID: familyID}
	if err := s.store.Save(ctx, token.HashRefreshToken(refresh), rec, s.refreshTTL); err != nil {
		return TokenPair{}, "", unavailable("save refresh token", err)
	}

	access, jti, err := s.issuer.Issue(client.ID, client.Scope)
	if err != nil {
		return TokenPair{}, "", err
	}

	return TokenPair{
		AccessToken:  access,
		AccessTTL:    s.issuer.TTL(),
		RefreshToken: refresh,
		RefreshTTL:   s.refreshTTL,
		Scope:        client.Scope,
	}, jti, nil
}

func unavailable(op string, err error) error {
	return fmt.Errorf("%w: %s: %w", ErrUnavailable, op, err)
}
