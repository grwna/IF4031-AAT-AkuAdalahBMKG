package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	refreshPrefix = "refresh:"
	usedPrefix    = "used:"
	familyPrefix  = "family:"
)

type RefreshRecord struct {
	ClientID string `json:"client_id"`
	FamilyID string `json:"family_id"`
}

type RedisStore struct {
	client *redis.Client
}

func NewRedisStore(client *redis.Client) *RedisStore {
	return &RedisStore{client: client}
}

func (s *RedisStore) Save(ctx context.Context, hash string, rec RefreshRecord, ttl time.Duration) error {
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("encode refresh record: %w", err)
	}
	return s.client.Set(ctx, refreshPrefix+hash, data, ttl).Err()
}

func (s *RedisStore) Consume(ctx context.Context, hash string) (RefreshRecord, bool, error) {
	data, err := s.client.GetDel(ctx, refreshPrefix+hash).Bytes()
	if errors.Is(err, redis.Nil) {
		return RefreshRecord{}, false, nil
	}
	if err != nil {
		return RefreshRecord{}, false, err
	}

	var rec RefreshRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return RefreshRecord{}, false, fmt.Errorf("decode refresh record: %w", err)
	}
	return rec, true, nil
}

func (s *RedisStore) MarkUsed(ctx context.Context, hash, familyID string, ttl time.Duration) error {
	return s.client.Set(ctx, usedPrefix+hash, familyID, ttl).Err()
}

func (s *RedisStore) UsedFamily(ctx context.Context, hash string) (string, bool, error) {
	fam, err := s.client.Get(ctx, usedPrefix+hash).Result()
	if errors.Is(err, redis.Nil) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return fam, true, nil
}

func (s *RedisStore) RevokeFamily(ctx context.Context, familyID string, ttl time.Duration) error {
	return s.client.Set(ctx, familyPrefix+familyID, "revoked", ttl).Err()
}

func (s *RedisStore) IsFamilyRevoked(ctx context.Context, familyID string) (bool, error) {
	n, err := s.client.Exists(ctx, familyPrefix+familyID).Result()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

func (s *RedisStore) Ping(ctx context.Context) error {
	return s.client.Ping(ctx).Err()
}
