# IF4031 Distributed Application Architecture Milestone 1

A disaster-coordination platform bridging BMKG, PVMBG, and BNPB.

**Course:** IF4031 – Distributed Application Architecture  
**Group:** AkuAdalahBMKG  
**Members:**
| Name | Student ID |
|---|---|
| M. Rayhan Farrukh | 13523035 |
| Alfian Hanif Fitria Yustanto | 13523073 |
| Carlo Angkisan | 13523091 |

---

## 1. Overview

This project implements a distributed disaster coordination platform centered around BNPB as the coordination hub, integrating two independent source agencies:
1. **BMKG**: Source for seismic activity and tsunami warnings (low latency, 50–150 ms).
2. **PVMBG**: Source for volcanic observation reports (high latency, 500–3000 ms, legacy infrastructure).

BNPB coordinates data collection through an **Aggregator** via periodic polling, maps heterogeneous payloads into a unified canonical model (`HazardEvent`), persists them into PostgreSQL using schema-less JSONB, broadcasts events via RabbitMQ topic exchange to downstream event consumers (`consumer-dashboard`, `consumer-notifier`, `consumer-pemda-volcano`), and exposes access-controlled HTTP endpoints through `client-api` backed by Ed25519 JWT tokens issued by `auth-service`.

- Architecture diagram: see [`docs/architecture-diagram.png`](docs/architecture-diagram.png) 
- Mermaid source: [`docs/architecture-diagram.mermaid`](docs/architecture-diagram.mermaid). 
- Full narrative: [`docs/architecture.md`](docs/architecture.md).

---

## 2. Technology Stack

| Category | Technology Used |
|---|---|
| Programming language | Go |
| Web framework | Go Standard Library `net/http` |
| Canonical Store database | PostgreSQL 16 (JSONB for dynamic attributes) |
| Message broker | RabbitMQ 4 (Alpine, Topic Exchange) |
| Token format & library | JWT (Ed25519 asymmetric signature), `github.com/golang-jwt/jwt/v5` |
| Refresh token store | Redis 7 (AOF persistence, token family tracking) |
| Structured logging | Go `log/slog` (JSON output with `correlation_id` & `duration_ms`) |
| Load testing engine | Custom Go benchmark runner (`scripts/load-test/run-load-test.sh`) & k6 |
| Container orchestration | Docker Compose v2 |

---

## 3. Repository Structure

```
project-root/
├── docker-compose.yml
├── .env.example
├── docs/
│   ├── architecture-diagram.mermaid
│   └── architecture-diagram.png
├── .bruno/
├── shared/
│   ├── envutil/
│   ├── httpclient/
│   ├── logger/
│   └── middleware/
├── scripts/
│   ├── gen-keys.sh
│   ├── demo/
│   │   └── demo.sh
│   ├── tests/
│   │   ├── test-e2e.sh
│   │   ├── test-aggregator.sh
│   │   ├── test-broker-integration.sh
│   │   └── test-services.sh
│   └── load-test/
│       ├── run-load-test.sh
│       └── k6-sustained.js
└── services/
    ├── bmkg-mock/
    ├── pvmbg-mock/
    ├── canonical-store/
    ├── aggregator/
    ├── client-api/
    ├── auth-service/
    ├── message-broker/
    ├── consumer-dashboard/
    └── consumer-notifier/
```

---

## 4. Prerequisites

- **Docker Engine** (v24.0 or newer) & **Docker Compose** (v2.20 or newer)
- **Host tools for running automated test suites & demo scripts**:
  - `bash` (v4+)
  - `curl`
  - `jq` (v1.6+)
  - `python3` (used by test scripts for high-precision latency checks)
- *(Optional)* **Go** 1.22+ (only needed if generating JWT keys or running services locally outside Docker)

---

## 5. Configuration Variables

Each service possesses its own `.env.example` file located in `services/<name>/.env.example`. All credentials and connection strings must be configured via environment variables.

### Global Root (`.env.example`)
Used for testing.

| Variable | Description | Default / Example |
|---|---|---|
| `BMKG_PORT` | Published host port for BMKG mock | `8081` |
| `PVMBG_PORT` | Published host port for PVMBG mock | `8082` |
| `AGGREGATOR_PORT` | Internal port for aggregator service | `8083` |
| `BNPB_CLIENT_API_PORT` | Published host port for Client-Facing API | `8080` |
| `AUTH_SERVICE_PORT` | Published host port for Auth Service | `8084` |
| `RABBITMQ_MGMT_PORT` | Published host port for RabbitMQ Management UI | `15672` |
| `POSTGRES_USER` | PostgreSQL superuser for canonical-store container | `aggregator_user` |
| `POSTGRES_PASSWORD` | PostgreSQL superuser password | `secret_postgres_pass` |
| `POSTGRES_DB` | Initial database name | `canonical_store` |
| `BMKG_API_KEY` | Mock API Key for BMKG | `bmkg-secret-key-123` |
| `PVMBG_BEARER_TOKEN` | Mock Bearer Token for PVMBG | `pvmbg-secret-token-abc` |

### Canonical Store (`services/canonical-store/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `POSTGRES_USER` | Database user for postgres image | `aggregator_user` |
| `POSTGRES_PASSWORD` | Database password (must match root `.env`) | `secret_postgres_pass` |
| `POSTGRES_DB` | Database name | `canonical_store` |

### BMKG Mock (`services/bmkg-mock/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP port | `8081` |
| `BMKG_API_KEY` | Expected header key for `X-BMKG-Key` | `bmkg-secret-key-123` |
| `BMKG_MIN_DELAY_MS` | Minimum simulated response delay | `50` |
| `BMKG_MAX_DELAY_MS` | Maximum simulated response delay | `150` |
| `BMKG_EVENT_INTERVAL_SEC` | Background event generation interval | `10` |

### PVMBG Mock (`services/pvmbg-mock/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP port | `8082` |
| `PVMBG_BEARER_TOKEN` | Expected token for `Authorization: Bearer <token>` | `pvmbg-secret-token-abc` |
| `PVMBG_MIN_DELAY_MS` | Minimum simulated response delay | `500` |
| `PVMBG_MAX_DELAY_MS` | Maximum simulated response delay | `3000` |
| `PVMBG_EVENT_INTERVAL_SEC` | Background event generation interval | `10` |

### Aggregator (`services/aggregator/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP port | `8083` |
| `DATABASE_URL` | PostgreSQL connection string (store-net) | `postgres://aggregator_user:secret_postgres_pass@canonical-store:5432/canonical_store?sslmode=disable` |
| `BMKG_URL` | BMKG mock base URL | `http://bmkg-mock:8081` |
| `BMKG_API_KEY` | API Key sent to BMKG | `bmkg-secret-key-123` |
| `PVMBG_URL` | PVMBG mock base URL | `http://pvmbg-mock:8082` |
| `PVMBG_TOKEN` | Bearer token sent to PVMBG | `pvmbg-secret-token-abc` |
| `POLL_INTERVAL` | Polling interval for source mocks | `3s` |
| `RABBITMQ_URL` | AMQP connection string | `amqp://bnpb:secret_rabbitmq_pass@message-broker:5672/` |
| `EXCHANGE_NAME` | RabbitMQ topic exchange name | `hazard.events` |
| `MAX_CONCURRENT_REQUESTS` | Concurrency limit on internal query handler | `100` |

### Auth Service (`services/auth-service/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP port | `8084` |
| `JWT_PRIVATE_KEY` | Base64-encoded PKCS#8 Ed25519 private key (from `./scripts/gen-keys.sh`) | *(base64 string)* |
| `JWT_ISSUER` | Expected JWT issuer claim (`iss`) | `bnpb-auth-service` |
| `JWT_AUDIENCE` | Expected JWT audience claim (`aud`) | `bnpb-client-api` |
| `ACCESS_TOKEN_TTL_SECONDS` | Access token lifespan | `60` |
| `REFRESH_TOKEN_TTL_SECONDS` | Refresh token lifespan | `3600` |
| `REDIS_ADDR` | Redis connection address (auth-net) | `auth-store:6379` |
| `CLIENT_MEDIA_ID` / `_SECRET` / `_SCOPE` | Client ID, Secret, and Scope for Media | `media-client` / `media-secret` / `hazards:read:summary` |
| `CLIENT_FIELD_ID` / `_SECRET` / `_SCOPE` | Client ID, Secret, and Scope for Field Team | `field-team` / `field-secret` / `hazards:read:raw` |
| `CLIENT_OPS_ID` / `_SECRET` / `_SCOPE` | Client ID, Secret, and Scope for BNPB Ops | `bnpb-ops` / `ops-secret` / `hazards:read:raw` |

### Client-Facing API (`services/client-api/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP port | `8080` |
| `JWT_PUBLIC_KEY` | Base64-encoded PKIX Ed25519 public key (pair of `JWT_PRIVATE_KEY`) | *(base64 string)* |
| `JWT_ISSUER` | Expected JWT issuer claim | `bnpb-auth-service` |
| `JWT_AUDIENCE` | Expected JWT audience claim | `bnpb-client-api` |
| `JWT_LEEWAY_SECONDS` | Clock skew tolerance for expiration | `0` |
| `AGGREGATOR_URL` | Internal Aggregator service URL | `http://aggregator:8083` |
| `AGGREGATOR_TIMEOUT_MS` | Timeout for outbound calls to Aggregator | `2000` |
| `MAX_CONCURRENT_REQUESTS` | Concurrency limit (excess receives HTTP 429) | `100` |

### Message Broker (`services/message-broker/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `RABBITMQ_DEFAULT_USER` | Default broker administrator | `bnpb` |
| `RABBITMQ_DEFAULT_PASS` | Default broker password (must match `RABBITMQ_URL`) | `secret_rabbitmq_pass` |

### Consumers (`services/consumer-dashboard/.env.example`, `services/consumer-notifier/.env.example`)
| Variable | Description | Default / Example |
|---|---|---|
| `PORT` | Listening HTTP health port | `8085` (dashboard), `8086` (notifier) |
| `RABBITMQ_URL` | AMQP connection string | `amqp://bnpb:secret_rabbitmq_pass@message-broker:5672/` |
| `EXCHANGE_NAME` | Target topic exchange | `hazard.events` |
| `QUEUE_NAME` | Target queue name | `dashboard` / `notifier` |
| `BINDING_KEYS` | Routing key patterns (comma-separated) | `#` |
| `PREFETCH` | Consumer prefetch count | `10` |

---

## 6. Running the System from Scratch

Follow these steps to bootstrap the system from a clean clone:

```bash
# 1. Clone the repository and enter the directory
git clone https://github.com/grwna/IF4031-AAT-AkuAdalahBMKG.git
cd IF4031-AAT-AkuAdalahBMKG

# 2. Copy all .env.example files to active .env files
cp .env.example .env
for s in services/*/; do
  if [ -f "${s}.env.example" ]; then
    cp "${s}.env.example" "${s}.env"
  fi
done

# 3. Synchronize passwords across service .env files
# Define your chosen shared passwords:
PG_PASS="secret_postgres_pass"
RABBIT_PASS="secret_rabbitmq_pass"

# Update PostgreSQL password in root, canonical-store, and aggregator:
sed -i "s|your-postgres-password-here|${PG_PASS}|g" .env services/canonical-store/.env services/aggregator/.env
sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASS}|g" .env services/canonical-store/.env

# Update RabbitMQ password in message-broker, aggregator, dashboard, and notifier:
sed -i "s|your-rabbitmq-password-here|${RABBIT_PASS}|g" \
  services/message-broker/.env \
  services/aggregator/.env \
  services/consumer-dashboard/.env \
  services/consumer-notifier/.env

# 4. Generate Ed25519 JWT keypair and inject into auth-service and client-api
# If Go is installed locally:
KEYS_OUTPUT=$(./scripts/gen-keys.sh)
PRIV_KEY=$(echo "$KEYS_OUTPUT" | grep '^JWT_PRIVATE_KEY=' | cut -d'=' -f2-)
PUB_KEY=$(echo "$KEYS_OUTPUT" | grep '^JWT_PUBLIC_KEY=' | cut -d'=' -f2-)

sed -i "s|^JWT_PRIVATE_KEY=.*|JWT_PRIVATE_KEY=${PRIV_KEY}|" services/auth-service/.env
sed -i "s|^JWT_PUBLIC_KEY=.*|JWT_PUBLIC_KEY=${PUB_KEY}|" services/client-api/.env

# (If Go is not installed on host, keys can be generated inside an ephemeral container):
# docker run --rm -v "$PWD:/app" -w /app/services/auth-service golang:1.22 go run ./tools/genkeys

# 5. Build and launch all containers
docker compose up --build -d

# 6. Verify health status of all running services
curl http://localhost:8081/health   # BMKG Mock
curl http://localhost:8082/health   # PVMBG Mock
curl http://localhost:8080/health   # Client-Facing API
curl http://localhost:8084/health   # Auth Service
docker compose exec aggregator wget -qO- http://localhost:8083/health   # Aggregator (internal)
docker compose exec consumer-dashboard wget -qO- http://localhost:8085/health # Dashboard Consumer
docker compose exec consumer-notifier wget -qO- http://localhost:8086/health  # Notifier Consumer
```

RabbitMQ Management Dashboard is accessible at `http://localhost:15672` (User: `bnpb`, Password: `secret_rabbitmq_pass`).

---

## 7. Services & Ports

| Service | Host Port (Default) | Network | Purpose |
|---|---|---|---|
| BMKG Mock | `8081` | bridge (`default`) | Seismic & tsunami warning simulation |
| PVMBG Mock | `8082` | bridge (`default`) | Volcanic report simulation & admin controls |
| Aggregator | `8083` (internal only) | `default`, `store-net` | Polling, canonical mapping, publishing, internal query API |
| Canonical Store | `5432` (internal only) | `store-net` (isolated) | PostgreSQL 16 JSONB storage for `hazard_events` |
| Client-Facing API | `8080` | bridge (`default`) | Downstream client entrypoint with token & scope enforcement |
| Auth/Token Service | `8084` | `default`, `auth-net` | Token issuer (Ed25519 JWT), refresh rotation |
| Auth Store | `6379` (internal only) | `auth-net` (isolated) | Redis 7 for refresh token hash family storage |
| Message Broker | `15672` (UI), `5672` (internal) | bridge (`default`) | RabbitMQ Topic Exchange `hazard.events` |
| Consumer – Dashboard | `8085` (internal only) | bridge (`default`) | Event subscriber (operations dashboard) |
| Consumer – Notifier | `8086` (internal only) | bridge (`default`) | Event subscriber (field alert notifications) |
| Consumer – Pemda Volcano | `8085` (profile: `p5-extra`) | bridge (`default`) | Event subscriber (regional portal demo) |

### Client-Facing API Endpoints

All endpoints except `/health` require an `Authorization: Bearer <access_token>` header issued by Auth Service.

| Endpoint | Media (`hazards:read:summary`) | Field Team / Ops (`hazards:read:raw`) |
|---|---|---|
| `GET /hazards` | HTTP 200 (7 Summary fields only) | HTTP 200 (All fields) |
| `GET /hazards?fields=a,b` | HTTP 200 (if summary only); HTTP 403 (if raw fields requested) | HTTP 200 |
| `GET /hazards/{hazard_id}` | HTTP 200 (Summary fields only) | HTTP 200 (All fields) |
| `GET /hazards/{hazard_id}/raw` | HTTP 403 `INSUFFICIENT_SCOPE` | HTTP 200 (`source_ref_id`, `latitude`, `longitude`, `attributes`) |
| `GET /health` | HTTP 200 (Public) | HTTP 200 (Public) |

- **Summary fields**: `hazard_id`, `source`, `hazard_type`, `severity`, `area_name`, `occurred_at`, `ingested_at`.
- **Raw fields**: `source_ref_id`, `latitude`, `longitude`, `attributes`.
- Supported query filters on `GET /hazards`: `type`, `source`, `severity`, `since`, `until`, `limit`, `cursor`.

---

## 8. Triggering Test Scenarios

### Automated Verification Suites

The repository provides automated test scripts formatted without ANSI color noise for standardized evaluation reporting:

```bash
# 1. Run all scenarios (includes 60s sustained load test & 60s token TTL wait):
./scripts/demo/demo.sh
# or via:
./scripts/tests/test-e2e.sh

# 2. Fast mode (shortened 10s load test and immediate token verification):
./scripts/demo/demo.sh --fast

# 3. Interactive step-by-step mode (pauses between each step for ENTER):
./scripts/demo/demo.sh p1 --step

# 4. Run an individual problem:
./scripts/demo/demo.sh p0   # Ketentuan Dasar & Ingest
./scripts/demo/demo.sh p1   # Schema Evolution
./scripts/demo/demo.sh p2   # Concurrency, Latency, & Outage
./scripts/demo/demo.sh p3   # Auth & Trust Domains
./scripts/demo/demo.sh p4   # Container Independence & Flexible Storage
./scripts/demo/demo.sh p5   # Pub/Sub Fan-out & Idempotency
```

Additional specialized integration tests are available in `scripts/tests/`:
- `./scripts/tests/test-aggregator.sh` - Deep unit and component testing for Aggregator mapping.
- `./scripts/tests/test-broker-integration.sh` - Dedicated RabbitMQ broker publishing & queue binding tests.
- `./scripts/tests/test-services.sh` - Cross-service connectivity and health checks.

### Manual Test Scenarios

Step-by-step manual commands for debugging, exploratory testing, or when automated scripts cannot run are documented in **[`docs/manual-tests.md`](docs/manual-tests.md)**.

