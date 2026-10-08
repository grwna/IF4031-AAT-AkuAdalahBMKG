import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Metrik Kustom sesuai Kriteria Penyelesaian Problem 2 (P2.1 & P2.2)
const bmkgOnlyLatency = new Trend('bmkg_only_latency_ms', true);
const allRequestLatency = new Trend('all_request_latency_ms', true);
const http200Count = new Counter('http_200_ok_total');
const http429Count = new Counter('http_429_controlled_rejection_total');
const uncontrolledErrors = new Counter('uncontrolled_error_total');
const uncontrolledErrorRate = new Rate('uncontrolled_error_rate');

const CLIENT_API_URL = __ENV.CLIENT_API_URL || 'http://localhost:8080';
const AUTH_URL = __ENV.AUTH_URL || 'http://localhost:8084';
const CLIENT_ID = __ENV.CLIENT_ID || 'bnpb-ops';
const CLIENT_SECRET = __ENV.CLIENT_SECRET || 'your-bnpb-ops-secret-here';
const VUS = parseInt(__ENV.VUS || '50', 10);
const DURATION = __ENV.DURATION || '60s';

export const options = {
  scenarios: {
    sustained_load: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    // Kriteria P2.1: p95 latensi permintaan BMKG-only tetap di bawah 300 ms
    bmkg_only_latency_ms: ['p(95)<300'],
    // Kriteria P2.2: Error rate di luar penolakan terkontrol (HTTP 429) wajib < 1%
    uncontrolled_error_rate: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
};

function issueToken() {
  const payload = JSON.stringify({
    grant_type: 'client_credentials',
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
  });
  const res = http.post(`${AUTH_URL}/token`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  if (res.status === 200) {
    const body = JSON.parse(res.body);
    return {
      accessToken: body.access_token,
      refreshToken: body.refresh_token,
      issuedAtMs: Date.now(),
      ttlMs: (body.expires_in || 60) * 1000,
    };
  }
  return null;
}

export function setup() {
  const tokenData = issueToken();
  if (!tokenData) {
    throw new Error(`Gagal memperoleh JWT token dari ${AUTH_URL}/token`);
  }
  return tokenData;
}

// Cache per-VU untuk memperbarui token sebelum TTL 60 detik habis di tengah load test 60s
let vuToken = null;
let vuTokenIssuedAt = 0;

function getActiveToken(setupData) {
  const now = Date.now();
  if (!vuToken) {
    vuToken = setupData.accessToken;
    vuTokenIssuedAt = setupData.issuedAtMs;
  }
  // Perbarui token setiap 40 detik agar tidak terkena 401 TOKEN_EXPIRED saat tes berjalan >= 60 detik
  if (now - vuTokenIssuedAt > 40000) {
    const refreshed = issueToken();
    if (refreshed && refreshed.accessToken) {
      vuToken = refreshed.accessToken;
      vuTokenIssuedAt = now;
    }
  }
  return vuToken;
}

export default function (setupData) {
  const token = getActiveToken(setupData);
  const headers = {
    Authorization: `Bearer ${token}`,
    'X-Correlation-ID': `k6-vu${__VU}-iter${__ITER}`,
  };

  // Campuran trafik: 50% BMKG-only (SEISMIC), 30% VOLCANIC, 20% Mixed/All
  const mod = __ITER % 10;
  let url = `${CLIENT_API_URL}/hazards?type=SEISMIC&limit=20`;
  let isBmkgOnly = true;

  if (mod >= 5 && mod < 8) {
    url = `${CLIENT_API_URL}/hazards?type=VOLCANIC&limit=20`;
    isBmkgOnly = false;
  } else if (mod >= 8) {
    url = `${CLIENT_API_URL}/hazards?limit=20`;
    isBmkgOnly = false;
  }

  const res = http.get(url, { headers });
  allRequestLatency.add(res.timings.duration);

  if (isBmkgOnly && res.status === 200) {
    bmkgOnlyLatency.add(res.timings.duration);
  }

  if (res.status === 200) {
    http200Count.add(1);
    uncontrolledErrorRate.add(false);
  } else if (res.status === 429) {
    // Penolakan terkontrol (HTTP 429) tidak dihitung sebagai kegagalan, namun tetap dilaporkan
    http429Count.add(1);
    uncontrolledErrorRate.add(false);
  } else {
    uncontrolledErrors.add(1);
    uncontrolledErrorRate.add(true);
  }

  check(res, {
    'status is 200 or controlled 429': (r) => r.status === 200 || r.status === 429,
  });

  sleep(0.05);
}
