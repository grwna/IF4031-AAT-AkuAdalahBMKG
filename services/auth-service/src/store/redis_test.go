package store_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"

	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/auth-service/src/store"
)

func newTestStore(t *testing.T) (*store.RedisStore, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { client.Close() })
	return store.NewRedisStore(client), mr
}

func TestStore_ConsumeOnlyOnce(t *testing.T) {
	s, _ := newTestStore(t)
	ctx := context.Background()
	rec := store.RefreshRecord{ClientID: "field-team", FamilyID: "fam-1"}
	if err := s.Save(ctx, "h1", rec, time.Hour); err != nil {
		t.Fatalf("Save: %v", err)
	}

	got, ok, err := s.Consume(ctx, "h1")
	if err != nil || !ok {
		t.Fatalf("first Consume: ok=%v err=%v", ok, err)
	}
	if got != rec {
		t.Errorf("got %+v, want %+v", got, rec)
	}

	if _, ok, _ := s.Consume(ctx, "h1"); ok {
		t.Fatal("second Consume should fail")
	}
}

func TestStore_RefreshExpires(t *testing.T) {
	s, mr := newTestStore(t)
	ctx := context.Background()
	_ = s.Save(ctx, "h1", store.RefreshRecord{ClientID: "c", FamilyID: "f"}, time.Minute)

	mr.FastForward(2 * time.Minute)

	if _, ok, _ := s.Consume(ctx, "h1"); ok {
		t.Fatal("expired token should not be consumable")
	}
}

func TestStore_UsedAndRevokedFamily(t *testing.T) {
	s, mr := newTestStore(t)
	ctx := context.Background()

	if _, ok, _ := s.UsedFamily(ctx, "h1"); ok {
		t.Fatal("unused hash should not be marked")
	}
	_ = s.MarkUsed(ctx, "h1", "fam-1", time.Hour)
	fam, ok, err := s.UsedFamily(ctx, "h1")
	if err != nil || !ok || fam != "fam-1" {
		t.Fatalf("UsedFamily = %q ok=%v err=%v", fam, ok, err)
	}

	if revoked, _ := s.IsFamilyRevoked(ctx, "fam-1"); revoked {
		t.Fatal("family should not be revoked yet")
	}
	_ = s.RevokeFamily(ctx, "fam-1", time.Hour)
	if revoked, _ := s.IsFamilyRevoked(ctx, "fam-1"); !revoked {
		t.Fatal("family should be revoked")
	}

	mr.FastForward(2 * time.Hour)
	if _, ok, _ := s.UsedFamily(ctx, "h1"); ok {
		t.Error("used marker should expire")
	}
	if revoked, _ := s.IsFamilyRevoked(ctx, "fam-1"); revoked {
		t.Error("revocation should expire")
	}
}

func TestStore_ConcurrentConsume(t *testing.T) {
	s, _ := newTestStore(t)
	ctx := context.Background()
	_ = s.Save(ctx, "h1", store.RefreshRecord{ClientID: "c", FamilyID: "f"}, time.Hour)

	var wins atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, ok, _ := s.Consume(ctx, "h1"); ok {
				wins.Add(1)
			}
		}()
	}
	wg.Wait()

	if wins.Load() != 1 {
		t.Fatalf("expected exactly 1 successful consume, got %d", wins.Load())
	}
}

func TestStore_PingFailsWhenRedisDown(t *testing.T) {
	s, mr := newTestStore(t)

	if err := s.Ping(context.Background()); err != nil {
		t.Fatalf("Ping: %v", err)
	}
	mr.Close()
	if err := s.Ping(context.Background()); err == nil {
		t.Fatal("Ping should fail when Redis is down")
	}
}
