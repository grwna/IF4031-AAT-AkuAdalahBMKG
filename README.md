# IF4031 Distributed Application Architecture Milestone 1

A disaster-coordination platform bridging BMKG, PVMBG, and BNPB.

**Course:** IF4031 – 
**Group:** AkuAdalahBMKG
**Members:**
| Name | Student ID |
|---|---|
| M. Rayhan Farrukh | 13523035 |
| Alfian Hanif Fitria Yustanto | 13523073 |
| Carlo Angkisan | 13523091 |

---

## 1. Overview

[OVERVIEW]

Full architecture diagram: see [`docs/architecture-diagram.*`](docs/architecture-diagram.png).

---

## 2. Technology Stack

| Category | Technology Used |
|---|---|
| Programming language | [ ] |
| Web framework | [ ] |
| Canonical Store database | [ ] |
| Message broker | [ ] |
| Token format/library | JWT (Ed25519), golang-jwt/jwt v5 |
| Refresh token store | Redis 7 |
| Structured logging | [ ] |
| Load testing | [ ] |
| Orchestration | Docker Compose |

Rationale for each technology choice: see the "Selected Technologies" section in the PDF report.

---

## 3. Repository Structure

```
project-root/
├── docker-compose.yml
├── .env.example
├── docs/
├── .bruno/
├── scripts/
│   ├── gen-keys.sh
│   ├── tests/
│   ├── load-test/
│   └── demo/
└── services/
    ├── bmkg-mock/
    ├── pvmbg-mock/
    ├── aggregator/
    ├── client-api/
    ├── auth-service/
    ├── consumer-dashboard/
    └── consumer-notifier/
```

---

## 4. Prerequisites

- Docker & Docker Compose (version [ ])
- [dll.]

---

## 5. Configuration Variables

> Each service also has its own `.env.example` file in its own folder (`services/<name>/.env.example`). The table below summarizes the main variables.

### Global (root `.env`)
| Variable | Description | Default |
|---|---|---|
| `BMKG_PORT` | BMKG mock port | `8081` |
| `PVMBG_PORT` | PVMBG mock port | `8082` |
| `BNPB_CLIENT_API_PORT` | Client-Facing API port | `8080` |
| `POLLING_INTERVAL_SECONDS` | Aggregator polling interval to the mocks | `[2-5]` |
| `PVMBG_DELAY_MIN_MS` / `PVMBG_DELAY_MAX_MS` | PVMBG random delay range | `500` / `3000` |

### BMKG Mock (`services/bmkg-mock/.env.example`)
| Variable | Description |
|---|---|
| `BMKG_API_KEY` | Valid X-BMKG-Key credential |
| `BMKG_FIXED_DELAY_MIN_MS` / `BMKG_FIXED_DELAY_MAX_MS` | Fixed 50–150ms delay |

### PVMBG Mock (`services/pvmbg-mock/.env.example`)
| Variable | Description |
|---|---|
| `PVMBG_TOKEN_SECRET` | PVMBG token signing key/format |

### Auth Service (`services/auth-service/.env.example`)
| Variable | Description | Default |
|---|---|---|
| `PORT` | Auth service port | `8084` |
| `JWT_PRIVATE_KEY` | Token signing key, from `scripts/gen-keys.sh` | - |
| `JWT_ISSUER` | Token issuer | `bnpb-auth-service` |
| `JWT_AUDIENCE` | Token audience | `bnpb-client-api` |
| `ACCESS_TOKEN_TTL_SECONDS` | Access token TTL | `60` |
| `REFRESH_TOKEN_TTL_SECONDS` | Refresh token TTL | `3600` |
| `REDIS_ADDR` | Redis address | - |
| `CLIENT_MEDIA_ID` / `_SECRET` / `_SCOPE` | Media client | - |
| `CLIENT_FIELD_ID` / `_SECRET` / `_SCOPE` | Field Team client | - |
| `CLIENT_OPS_ID` / `_SECRET` / `_SCOPE` | BNPB Ops client | - |

### Client-Facing API (`services/client-api/.env.example`)
| Variable | Description | Default |
|---|---|---|
| `PORT` | Client-Facing API port | `8080` |
| `JWT_PUBLIC_KEY` | Token verification key, from `scripts/gen-keys.sh` (must be the pair of the auth service's `JWT_PRIVATE_KEY`) | - |
| `JWT_ISSUER` | Expected token issuer, must match the auth service | `bnpb-auth-service` |
| `JWT_AUDIENCE` | Expected token audience, must match the auth service | `bnpb-client-api` |
| `JWT_LEEWAY_SECONDS` | Clock skew tolerance for `exp` | `0` |
| `AGGREGATOR_URL` | Aggregator internal API base URL | - |
| `AGGREGATOR_TIMEOUT_MS` | Timeout for each call to the aggregator | `2000` |
| `MAX_CONCURRENT_REQUESTS` | Data requests processed at once; extra requests get `429` | `100` |

### Bruno (`.bruno/.env`)
| Variable | Description |
|---|---|
| `BMKG_API_KEY` | Same as BMKG mock |
| `PVMBG_BEARER_TOKEN` | Same as PVMBG mock |
| `CLIENT_MEDIA_SECRET` / `CLIENT_FIELD_SECRET` / `CLIENT_OPS_SECRET` | Same as auth service |

*(Fill in as needed for each service — no real credentials should ever be committed, only example values.)*

---

## 6. Running the System 

```bash
# 1. Clone the repo and enter the folder
git clone https://github.com/grwna/IF4031-AAT-AkuAdalahBMKG.git
cd IF4031-AAT-AkuAdalahBMKG

# 2. Copy the configuration files
cp .env.example .env
# also copy each services/<name>/.env.example to .env

# 3. Generate JWT keys, put JWT_PRIVATE_KEY in services/auth-service/.env and JWT_PUBLIC_KEY in services/client-api/.env
./scripts/gen-keys.sh

# 4. Start the whole system
docker compose up --build

# Verify every service is healthy
curl http://localhost:8081/health   # BMKG
curl http://localhost:8082/health   # PVMBG
curl http://localhost:8080/health   # Client-Facing API
curl http://localhost:8084/health   # Auth Service
# [add health checks for other services]
```

Seed data (≥20 historical records) is automatically available in BMKG & PVMBG on first startup.

---

## 7. Services & Ports

| Service | Port | Description |
|---|---|---|
| BMKG Mock | 8081 | Simulated seismic & tsunami data |
| PVMBG Mock | 8082 | Simulated volcanic data |
| Aggregator | [ ] | Polling, mapping, publishing to the broker |
| Canonical Store | [ ] | HazardEvent storage |
| Client-Facing API | 8080 | Endpoint for downstream clients |
| Auth/Token Service | 8084 | Token issuance & refresh |
| Auth Store | - | Redis for refresh tokens (internal) |
| Message Broker | [ ] | HazardEvent fan-out |
| Consumer – Dashboard | [ ] | Example subscriber 1 |
| Consumer – Notifier | [ ] | Example subscriber 2 |

### Client-Facing API Endpoints

All endpoints except `/health` require `Authorization: Bearer <access_token>` from the auth service.

| Endpoint | Media (`hazards:read:summary`) | Field Team / Ops (`hazards:read:raw`) |
|---|---|---|
| `GET /hazards` | `200`, summary fields only | `200`, all fields |
| `GET /hazards?fields=a,b` | `200` if all summary fields, `403` if any raw field | `200` |
| `GET /hazards/{hazard_id}` | `200`, summary fields only | `200`, all fields |
| `GET /hazards/{hazard_id}/raw` | `403` | `200` (`source_ref_id`, `latitude`, `longitude`, `attributes`) |
| `GET /health` | no token needed | no token needed |

Summary fields: `hazard_id`, `source`, `hazard_type`, `severity`, `area_name`, `occurred_at`, `ingested_at`. Raw fields: `source_ref_id`, `latitude`, `longitude`, `attributes`.

`GET /hazards` forwards the filters `type`, `source`, `severity`, `since`, `until`, `limit`, `cursor` to the aggregator. Every data response carries `source_status` from the aggregator. Errors use `{"error":{"code":"...","message":"..."}}`: `401` (`MISSING_TOKEN`, `INVALID_TOKEN`, `TOKEN_EXPIRED`), `403` (`INSUFFICIENT_SCOPE`), `429` (`TOO_MANY_REQUESTS`), `503` (`UPSTREAM_UNAVAILABLE`, aggregator unreachable).

---

## 8. Triggering Test Scenarios per Problem

### P1 — Schema Evolution
```bash
# Run the system with PVMBG's initial schema, observe the resulting HazardEvents
# Then trigger a schema change without restarting anything:
curl -X POST http://localhost:8082/admin/schema-version -d '{"confidence_level_enabled": true}'
# Verify the Aggregator keeps producing valid HazardEvents, check logs/attributes
```

### P2 — Concurrency & Graceful Degradation
```bash
# Test BMKG-only latency while PVMBG delay is set to 3 seconds
# [command/script to generate concurrent requests]

# Load test (>=50 parallel connections, 60 seconds)
[k6/Locust command] scripts/load-test/[script-name]

# Simulate a PVMBG outage
curl -X POST http://localhost:8082/admin/outage -d '{"enabled": true}'
# ... observe degradation behavior ...
curl -X POST http://localhost:8082/admin/outage -d '{"enabled": false}'
```

### P3 — Auth & Trust Domains
```bash
# Show that a BMKG credential is rejected by PVMBG and vice versa
curl -H "X-BMKG-Key: <bmkg-key>" http://localhost:8082/volcanic-reports  # should be 401/403

# Get a token (Media: media-client, Field Team: field-team, Ops: bnpb-ops)
curl -X POST http://localhost:8084/token \
  -d '{"grant_type":"client_credentials","client_id":"field-team","client_secret":"<field-secret>"}'

# Media only receives summary fields (no source_ref_id, latitude, longitude, attributes)
curl -H "Authorization: Bearer <media-token>" http://localhost:8080/hazards

# Media explicitly requesting raw fields is rejected by the server
curl -H "Authorization: Bearer <media-token>" "http://localhost:8080/hazards?fields=severity,latitude"  # 403 INSUFFICIENT_SCOPE
curl -H "Authorization: Bearer <media-token>" http://localhost:8080/hazards/<hazard-id>/raw            # 403 INSUFFICIENT_SCOPE

# Field Team receives raw fields
curl -H "Authorization: Bearer <field-token>" http://localhost:8080/hazards/<hazard-id>/raw            # 200

# Wait for the Field Team access token TTL (default 60s): the old access token is rejected
curl -H "Authorization: Bearer <field-token>" http://localhost:8080/hazards                            # 401 TOKEN_EXPIRED

# Refresh without logging in again, then use the new access token
curl -X POST http://localhost:8084/refresh -d '{"refresh_token":"<refresh-token>"}'
curl -H "Authorization: Bearer <new-field-token>" http://localhost:8080/hazards                        # 200

# Reusing the old refresh token should be 401
curl -X POST http://localhost:8084/refresh -d '{"refresh_token":"<old-refresh-token>"}'
```

With Bruno: run the `auth` folder, then the `client-api` folder (CLI: `npx @usebruno/cli run auth client-api --env Local` from `.bruno/`). To show the expired token, use the Bruno app (tokens are kept between requests in the same session): run `auth`, wait more than 60 seconds, then run `client-api/Hazards Old Access Token` (expects `401 TOKEN_EXPIRED`).

### P4 — Microservice Architecture & Flexible Storage
```bash
# Restart one container without disrupting the others
docker compose restart aggregator
# Verify other services keep responding during this process

# Verify records from before and after confidence_level was introduced
# coexist and are both readable
[Canonical Store query command]
```

### P5 — Pub/Sub Fan-out
```bash
# Stop one of the consumers
docker compose stop consumer-notifier

# Verify the producer and the other consumer keep working normally, then restart it
docker compose start consumer-notifier
# Observe whether events published while the consumer was down are caught up or lost

# Add a new consumer without changing any producer code
[steps to add a new consumer]
```

---

## 9. LLM Usage Declaration

[Explain which parts were assisted by an LLM, per the assignment's Writing Requirements — this must be explicitly declared.]

---

## 10. Limitations & Assumptions

[Summary of technical limitations/assumptions; full details are in the PDF report's "Assumptions" and "Known Limitations" sections per problem.]