# Arsitektur Sistem - IF4031 Milestone 1

## Diagram

**Mermaid source**: [`architecture-diagram.mermaid`](architecture-diagram.mermaid)

**Rendered image**: [`architecture-diagram.png`](architecture-diagram.png)

---

## Penjelasan Naratif

### Gambaran Umum

Sistem ini merupakan platform koordinasi kebencanaan terdistribusi dengan BNPB sebagai node koordinasi sentral. Dua instansi sumber data eksternal berperan pasif: keduanya hanya merespons polling, tidak pernah menginisiasi koneksi keluar. Seluruh sistem berjalan sebagai satu orkestrasi Docker Compose dengan 11 container.

---

### Batas Container & Jaringan

Sistem dibagi menjadi tiga lapisan jaringan Docker:

| Jaringan | Tipe | Isi |
|---|---|---|
| `default` (bridge) | Terbuka ke host | bmkg-mock, pvmbg-mock, aggregator, client-api, auth-service, message-broker, consumer-dashboard, consumer-notifier |
| `store-net` | `internal: true` | aggregator ↔ canonical-store |
| `auth-net` | `internal: true` | auth-service ↔ auth-store |

`store-net` dan `auth-net` diberi flag `internal: true` sehingga tidak dapat diakses dari host maupun internet. Ini menegakkan bahwa canonical-store (PostgreSQL) dan auth-store (Redis) hanya dapat dijangkau oleh komponen yang secara eksplisit terdaftar di jaringan tersebut — bukan oleh client-api, consumer, atau siapapun selain pemiliknya.

Port yang dipublikasikan ke host hanya port yang memang dibutuhkan oleh pihak luar: BMKG mock (8081), PVMBG mock (8082), client-api (8080), auth-service (8084), dan RabbitMQ Management UI (15672). Aggregator, canonical-store, auth-store, dan AMQP (5672) tidak dipublikasikan.

---

### Alur Ingest Data (Polling)

```
aggregator  --HTTP GET /seismic-events?since=...--> bmkg-mock   (Header: X-BMKG-Key)
aggregator  --HTTP GET /tsunami-warnings?since=..--> bmkg-mock   (Header: X-BMKG-Key)
aggregator  --HTTP GET /volcanic-reports?since=..-> pvmbg-mock   (Header: Authorization: Bearer)
```

Aggregator melakukan polling berkala (interval dikonfigurasi via `POLL_INTERVAL`) ke kedua mock secara **konkuren** menggunakan goroutine terpisah. BMKG dan PVMBG dipool secara independen, sehingga lambatnya PVMBG (500–3000 ms) tidak memblokir ingesti data BMKG. Parameter `?since=<timestamp>` digunakan untuk incremental polling, menghindari re-ingesti data historis.

Setiap record yang masuk dipetakan ke format kanonik `HazardEvent` dengan 11 field tetap, lalu di-upsert ke canonical-store menggunakan `source` + `source_ref_id` sebagai kunci komposit untuk menjamin idempotency.

---

### Kepemilikan Penyimpanan

**Canonical Store (PostgreSQL 16)** dimiliki eksklusif oleh `aggregator`. Hanya aggregator yang memiliki `DATABASE_URL` dalam konfigurasinya dan yang terhubung ke `store-net`. `client-api` mengambil data melalui internal HTTP API milik aggregator (`GET /internal/hazards`), bukan langsung ke database.

Pemisahan ini mencegah coupling langsung antara storage dan presentasi layer, serta memungkinkan skema database berkembang (misalnya penambahan kolom JSONB `attributes`) tanpa harus mengubah `client-api`.

**Auth Store (Redis 7, AOF persistence)** dimiliki eksklusif oleh `auth-service`. Redis menyimpan hash refresh token beserta family ID-nya untuk mendeteksi refresh token reuse (jika token lama dipakai ulang setelah rotasi, seluruh family dicabut). Hanya `auth-service` yang terhubung ke `auth-net`.

**Keputusan JSONB**: Field `attributes` di tabel `hazard_events` menggunakan tipe `jsonb` PostgreSQL. Ini memungkinkan field dinamis seperti `confidence_level` dari PVMBG masuk ke record baru tanpa DDL migration, sementara record lama tanpa field tersebut tetap valid berdampingan, sesuai syarat P4.

---

### Alur Distribusi Event (Pub/Sub)

```
aggregator  --AMQP Publish (Confirm Mode)--> Exchange: hazard.events (topic, durable)
Exchange    --Binding key: # ------------> Queue: dashboard  --> consumer-dashboard
Exchange    --Binding key: # ------------> Queue: notifier   --> consumer-notifier
Exchange    --Binding key: volcanic ------> Queue: pemda-volcano --> consumer-pemda-volcano (profile p5-extra)
```

Aggregator mempublikasikan setiap `HazardEvent` ke RabbitMQ topic exchange `hazard.events` secara asinkron menggunakan **publisher confirm mode**, sehingga publish tidak memblokir polling loop berikutnya. Routing key yang digunakan: `seismic` (dari BMKG) dan `volcanic` (dari PVMBG).

Pemilihan **topic exchange** (bukan fanout) memungkinkan consumer baru dengan routing key spesifik bergabung tanpa mengubah producer, seperti `consumer-pemda-volcano` yang hanya menerima event `volcanic`. Menambah consumer baru benar-benar zero-change pada aggregator.

Queue `dashboard` dan `notifier` bersifat **durable** dengan **manual acknowledgment**. Jika salah satu consumer mati, pesan tetap tersimpan di queue dan akan diproses saat consumer hidup kembali, sesuai dengan at-least-once delivery guarantee.

`consumer-notifier` mengimplementasikan idempotency berbasis `hazard_id + severity` untuk mendeteksi duplikat: event pertama diproses (`notification_sent`), duplikat persis di-skip (`notification_skipped_duplicate`), perubahan severity diproses ulang sebagai update. Payload malformed di-reject tanpa requeue untuk menghindari infinite retry loop.

---

### Alur Autentikasi & Akses Client

```
client  --POST /token (client_id, client_secret)--> auth-service
auth-service --> Redis: simpan refresh token + family
auth-service --> client: {access_token (JWT Ed25519, TTL 60s), refresh_token}

client  --GET /hazards (Bearer JWT)----------> client-api
client-api  (verifikasi JWT lokal, tanpa call ke auth-service)
client-api  --GET /internal/hazards----------> aggregator (Header: X-Correlation-ID)
aggregator  --query-----------------------> canonical-store
```

**Ed25519 asymmetric JWT** digunakan agar `client-api` dapat memverifikasi token secara lokal menggunakan public key, sehingga tidak perlu memanggil `auth-service` untuk setiap request. Hal ini membuat `auth-service` dapat dimatikan dan `client-api` tetap melayani request dengan token yang belum kedaluwarsa, sesuai syarat P4.

Setiap token membawa `scope` claim (`hazards:read:summary` atau `hazards:read:raw`). `client-api` menegakkan scope di sisi server: Media yang mencoba mengakses field raw mendapat HTTP 403 `INSUFFICIENT_SCOPE` dari server, bukan sekadar disembunyikan di UI.

**Refresh token rotation**: Setiap refresh menghasilkan pasangan token baru dan mencabut token lama. Jika token lama dipakai ulang (replay attack), seluruh family dicabut otomatis.

---

### Protokol Komunikasi Antar-Service

| Dari | Ke | Protokol | Detail |
|---|---|---|---|
| aggregator | bmkg-mock | HTTP/1.1 | `GET /seismic-events`, `GET /tsunami-warnings` dengan header `X-BMKG-Key` |
| aggregator | pvmbg-mock | HTTP/1.1 | `GET /volcanic-reports` dengan header `Authorization: Bearer` |
| aggregator | canonical-store | TCP/PostgreSQL | Driver `pgx/v5`, upsert JSONB, keyset pagination |
| aggregator | message-broker | AMQP 0-9-1 | Publisher confirm mode, topic exchange, routing key `seismic`/`volcanic` |
| client-api | aggregator | HTTP/1.1 | Internal: `GET /internal/hazards`, `GET /internal/hazards/{id}`, `GET /internal/source-status` dengan header `X-Correlation-ID` |
| auth-service | auth-store | TCP/RESP | Driver `go-redis/v9`, hash refresh token & family tracking |
| message-broker | consumer-* | AMQP 0-9-1 | Push ke durable queue, manual ack, prefetch 10 |
| client-* | auth-service | HTTP/1.1 | `POST /token`, `POST /refresh` |
| client-* | client-api | HTTP/1.1 | `GET /hazards`, header `Authorization: Bearer <JWT>` |

`X-Correlation-ID` dipropagasi dari client → client-api → aggregator dan dicatat di structured log (`log/slog`) semua service beserta `duration_ms` panggilan keluar, memenuhi syarat observability.

---

### Ketahanan & Degradasi Graceful

Saat PVMBG mengalami outage (`POST /admin/outage`):
- Aggregator gagal polling PVMBG, mencatat status `DEGRADED` dengan timestamp `stale_since`.
- Request data seismik (BMKG) tetap dilayani normal.
- Request data vulkanik dijawab dengan data terakhir dari canonical-store beserta `source_status.PVMBG.status = "DEGRADED"` dan `stale_since`, tidak pernah HTTP 500 atau hang.
- Saat outage dimatikan, aggregator pulih otomatis pada polling berikutnya tanpa restart.

Polling BMKG dan PVMBG berjalan di goroutine terpisah, sehingga PVMBG yang lambat atau mati tidak memblokir ingesti data BMKG, sesuai dengan head-of-line blocking prevention.
