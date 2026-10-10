# Manual Test Scenarios

This document contains step-by-step manual commands for verifying each problem requirement. Use these for debugging, exploratory testing, or when automated scripts cannot run.

---

## Skenario P0 — Ketentuan Dasar & Ingest

```bash
# P0.1 Health check across all 7 services:
curl -s http://localhost:8081/health
curl -s http://localhost:8082/health
curl -s http://localhost:8080/health
curl -s http://localhost:8084/health
docker compose exec -T aggregator wget -qO- http://localhost:8083/health
docker compose exec -T consumer-dashboard wget -qO- http://localhost:8085/health
docker compose exec -T consumer-notifier wget -qO- http://localhost:8086/health

# P0.2 Verify initial historical seed data (>= 20 records each) and separate /tsunami-warnings:
curl -s -H "X-BMKG-Key: bmkg-secret-key-123" http://localhost:8081/seismic-events | jq 'length'
curl -s -H "X-BMKG-Key: bmkg-secret-key-123" http://localhost:8081/tsunami-warnings | jq 'length'
curl -s -H "Authorization: Bearer pvmbg-secret-token-abc" http://localhost:8082/volcanic-reports | jq 'length'

# P0.3 Verify mock latency characteristics (BMKG 50-150ms vs PVMBG 500-3000ms):
curl -s -o /dev/null -w "BMKG time: %{time_total}s\n" -H "X-BMKG-Key: bmkg-secret-key-123" http://localhost:8081/seismic-events
curl -s -o /dev/null -w "PVMBG time: %{time_total}s\n" -H "Authorization: Bearer pvmbg-secret-token-abc" http://localhost:8082/volcanic-reports

# P0.4 Verify X-Correlation-ID propagation into structured logs:
OPS_TOKEN=$(curl -s -X POST http://localhost:8084/token -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials","client_id":"bnpb-ops","client_secret":"ops-secret"}' | jq -r '.access_token')

curl -s -H "Authorization: Bearer ${OPS_TOKEN}" -H "X-Correlation-ID: trace-p0-demo" http://localhost:8080/hazards?limit=1
docker compose logs --tail=50 client-api | grep "trace-p0-demo"
docker compose logs --tail=50 aggregator | grep "trace-p0-demo"

# P0.5 Verify code isolation (zero cross-service package imports):
for s in services/*/; do
  n=$(basename "$s")
  grep -rn 'AkuAdalahBMKG/services/' --include='*.go' "$s" 2>/dev/null | grep -v "services/$n/" || true
done

# P0.6 Verify internal ports are not published to host:
docker compose port aggregator 8083 || echo "Aggregator port safely isolated"
docker compose port canonical-store 5432 || echo "PostgreSQL port safely isolated"
docker compose port auth-store 6379 || echo "Redis port safely isolated"
docker compose port message-broker 5672 || echo "AMQP port safely isolated"

# P0.7 Verify passive mock with ?since= parameter filter:
SINCE=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s -H "X-BMKG-Key: bmkg-secret-key-123" "http://localhost:8081/seismic-events?since=${SINCE}"

# P0.8 Verify no duplicate rows in Canonical Store and full 11 canonical fields:
docker compose exec -T canonical-store psql -U aggregator_user -d canonical_store -c \
  "SELECT source, source_ref_id, count(*) FROM hazard_events GROUP BY 1,2 HAVING count(*) > 1;"
```

---

## Skenario P1 — Schema Evolution

```bash
# 1. Fetch initial volcanic records (confirm absence of confidence_level):
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" "http://localhost:8080/hazards?type=VOLCANIC&limit=5" \
  | jq '.data[] | {hazard_id, attributes}'

# 2. Trigger runtime schema evolution on PVMBG mock without restarting any service:
curl -s -X POST http://localhost:8082/admin/schema-version \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer pvmbg-secret-token-abc" \
  -d '{"enabled": true}'

# 3. Observe new volcanic events ingested with confidence_level inside attributes:
sleep 6
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" "http://localhost:8080/hazards?type=VOLCANIC&limit=5" \
  | jq '.data[] | select(.attributes.confidence_level != null) | {hazard_id, attributes}'

# 4. Reset schema evolution flag after test:
curl -s -X POST http://localhost:8082/admin/schema-version \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer pvmbg-secret-token-abc" \
  -d '{"enabled": false}'
```

---

## Skenario P2 — Concurrency & Graceful Degradation

```bash
# 1. Head-of-line blocking test (BMKG p95 latency < 300ms while PVMBG has 3s delay):
./scripts/load-test/run-load-test.sh --mode p21 --no-save

# 2. Sustained load test (55 parallel VUs for >= 60 seconds, error rate < 1%):
./scripts/load-test/run-load-test.sh --mode p22 --vus 55 --duration 60 --no-save
# Or quick benchmark (10s):
./scripts/load-test/run-load-test.sh --quick

# 3. Trigger simulated outage on PVMBG mock:
curl -s -X POST http://localhost:8082/admin/outage \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer pvmbg-secret-token-abc" \
  -d '{"outage": true}'

# 4. Verify PVMBG directly responds HTTP 503:
curl -i -s -H "Authorization: Bearer pvmbg-secret-token-abc" http://localhost:8082/volcanic-reports

# 5. Verify Client-API continues serving BMKG seismic data normally (HTTP 200):
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" "http://localhost:8080/hazards?type=SEISMIC&limit=1" | jq .source_status

# 6. Verify Client-API serves stale volcanic data from Canonical Store with status DEGRADED & stale_since:
sleep 4
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" "http://localhost:8080/hazards?type=VOLCANIC&limit=1" \
  | jq '{source_status: .source_status, sample_record: .data[0].hazard_id}'

# 7. Disable outage and verify automatic recovery without restart:
curl -s -X POST http://localhost:8082/admin/outage \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer pvmbg-secret-token-abc" \
  -d '{"outage": false}'
sleep 4
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" "http://localhost:8080/hazards?limit=1" | jq .source_status
```

---

## Skenario P3 — Auth & Trust Domains

```bash
# 1. Cross-domain credential rejection:
curl -i -s -H "X-BMKG-Key: bmkg-secret-key-123" http://localhost:8082/volcanic-reports            # 401 Unauthorized
curl -i -s -H "Authorization: Bearer pvmbg-secret-token-abc" http://localhost:8081/seismic-events # 401 Unauthorized

# 2. Acquire token for Media client (scope: hazards:read:summary):
MEDIA_TOKEN=$(curl -s -X POST http://localhost:8084/token -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials","client_id":"media-client","client_secret":"media-secret"}' | jq -r '.access_token')

# 3. Media receives summary fields only:
curl -s -H "Authorization: Bearer ${MEDIA_TOKEN}" http://localhost:8080/hazards?limit=1 | jq .data[0]

# 4. Explicit request for raw field by Media is rejected with HTTP 403 INSUFFICIENT_SCOPE:
curl -i -s -H "Authorization: Bearer ${MEDIA_TOKEN}" "http://localhost:8080/hazards?fields=severity,latitude"
curl -i -s -H "Authorization: Bearer ${MEDIA_TOKEN}" http://localhost:8080/hazards/BMKG-seismic-0001/raw

# 5. Acquire token for Field Team (scope: hazards:read:raw):
FIELD_RESP=$(curl -s -X POST http://localhost:8084/token -H "Content-Type: application/json" \
  -d '{"grant_type":"client_credentials","client_id":"field-team","client_secret":"field-secret"}')
FIELD_TOKEN=$(echo "$FIELD_RESP" | jq -r '.access_token')
REFRESH_TOKEN=$(echo "$FIELD_RESP" | jq -r '.refresh_token')

# 6. Field Team receives raw attributes:
curl -s -H "Authorization: Bearer ${FIELD_TOKEN}" http://localhost:8080/hazards/BMKG-seismic-0001/raw | jq .data

# 7. Wait for access token TTL expiration (60s):
sleep 62
curl -i -s -H "Authorization: Bearer ${FIELD_TOKEN}" http://localhost:8080/hazards?limit=1 # 401 TOKEN_EXPIRED

# 8. Refresh access token using refresh_token without re-entering credentials:
NEW_RESP=$(curl -s -X POST http://localhost:8084/refresh -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"${REFRESH_TOKEN}\"}")
NEW_FIELD_TOKEN=$(echo "$NEW_RESP" | jq -r '.access_token')
curl -s -H "Authorization: Bearer ${NEW_FIELD_TOKEN}" http://localhost:8080/hazards?limit=1 # 200 OK

# 9. Reuse of old refresh token is rejected (refresh token rotation & reuse detection):
curl -i -s -X POST http://localhost:8084/refresh -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"${REFRESH_TOKEN}\"}" # 401 invalid_grant
```

---

## Skenario P4 — Microservice Architecture & Flexible Storage

```bash
# 1. Independent restart test for auth-service (client-api continues verifying existing JWTs locally):
docker compose stop auth-service
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" http://localhost:8080/hazards?limit=1 | jq '.data | length' # 200 OK
docker compose start auth-service

# 2. Independent restart test for aggregator:
docker compose stop aggregator
curl -i -s -H "Authorization: Bearer ${OPS_TOKEN}" http://localhost:8080/hazards?limit=1 # 503 UPSTREAM_UNAVAILABLE
docker compose start aggregator
sleep 4
curl -s -H "Authorization: Bearer ${OPS_TOKEN}" http://localhost:8080/hazards?limit=1 # 200 OK

# 3. Verify coexistence of records before and after schema evolution in PostgreSQL JSONB:
docker compose exec -T canonical-store psql -U aggregator_user -d canonical_store -c \
  "SELECT hazard_id, (attributes ? 'confidence_level') AS has_confidence_level, attributes FROM hazard_events WHERE hazard_type = 'VOLCANIC' ORDER BY (attributes ? 'confidence_level') DESC, occurred_at DESC LIMIT 6;"

# 4. Verify Canonical Store isolation (only aggregator holds DATABASE_URL):
grep -rn "DATABASE_URL" services/*/.env.example
```

---

## Skenario P5 — Pub/Sub Fan-out & Idempotensi

```bash
# 1. Verify queue bindings on exchange hazard.events:
curl -s -u bnpb:secret_rabbitmq_pass http://localhost:15672/api/exchanges/%2F/hazard.events/bindings/source \
  | jq 'map({destination, routing_key})'

# 2. Verify independent receipt of events on consumer-dashboard and consumer-notifier:
docker compose logs --tail=10 consumer-dashboard | grep "hazard_event_received"
docker compose logs --tail=10 consumer-notifier | grep "hazard_event_received"

# 3. Stop consumer-notifier, produce events, verify durable queue buffering:
docker compose stop consumer-notifier
sleep 6
curl -s -u bnpb:secret_rabbitmq_pass http://localhost:15672/api/queues/%2F/notifier \
  | jq '{name, messages_ready, messages_unacknowledged}'

# 4. Verify consumer-dashboard continues real-time processing while notifier is stopped:
docker compose logs --tail=10 consumer-dashboard | grep "hazard_event_received"

# 5. Start consumer-notifier and verify backlog catch-up:
docker compose start consumer-notifier
sleep 4
docker compose logs --tail=20 consumer-notifier | grep "hazard_event_received"

# 6. Dynamically add consumer-3 (consumer-pemda-volcano) without changing producer code:
docker compose --profile p5-extra up -d consumer-pemda-volcano
sleep 6
docker compose --profile p5-extra logs --tail=15 consumer-pemda-volcano
docker compose --profile p5-extra stop consumer-pemda-volcano

# 7. Test at-least-once duplicate deduplication and malformed payload rejection on consumer-notifier:
# Publish duplicated event:
PAYLOAD=$(jq -cn '{hazard_id:"QA-DUP-01",source:"BMKG",source_ref_id:"dup-01",hazard_type:"SEISMIC",severity:"SIAGA",area_name:"Uji QA",latitude:-6.2,longitude:106.8,occurred_at:"2026-10-09T00:00:00Z",ingested_at:"2026-10-09T00:00:00Z",attributes:{}}')
MSG=$(jq -cn --arg pl "$PAYLOAD" '{routing_key:"seismic",payload:$pl,payload_encoding:"string",properties:{message_id:"QA-DUP-01:SIAGA",delivery_mode:2}}')
curl -s -u bnpb:secret_rabbitmq_pass -X POST http://localhost:15672/api/exchanges/%2F/hazard.events/publish -H "Content-Type: application/json" -d "$MSG"
curl -s -u bnpb:secret_rabbitmq_pass -X POST http://localhost:15672/api/exchanges/%2F/hazard.events/publish -H "Content-Type: application/json" -d "$MSG"

# Check consumer-notifier log for deduplication skipping:
docker compose logs --tail=20 consumer-notifier | grep "notification_skipped_duplicate"
```