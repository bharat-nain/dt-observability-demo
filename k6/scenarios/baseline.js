/**
 * k6 Baseline Load Test -- DT Wealth Platform Demo
 *
 * Simulates a normal trading day: 20 concurrent advisers browsing the
 * platform, searching for journeys (mapped as portfolio/fund lookups),
 * and submitting booking requests (mapped as trade orders).
 *
 * EasyTravel endpoints confirmed working:
 *   GET  /                        -> Adviser portal homepage (JSF)
 *   GET  /orange.jsf              -> Main portal
 *   GET  /special-offers.jsp      -> Special offers / featured products
 *   GET  /about-orange.jsf        -> About page
 *   GET  /contact-orange.jsf      -> Contact page
 *   POST /orange.jsf              -> Login / search form submission
 *
 * Purpose: establishes clean baseline telemetry in Dynatrace before spike.
 * Run time: 5 minutes @ 20 VUs
 *
 * Usage:
 *   k6 run k6/scenarios/baseline.js -e APP_HOST=<instance-ip>
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom metrics ────────────────────────────────────────────────────────────
const errorRate       = new Rate('dt_error_rate');
const pageLoadTime    = new Trend('dt_page_load_ms', true);
const successfulLoads = new Counter('dt_successful_page_loads');

// ── Config ────────────────────────────────────────────────────────────────────
const APP_HOST = __ENV.APP_HOST || 'localhost';
const BASE_URL  = `http://${APP_HOST}`;

export const options = {
  scenarios: {
    adviser_sessions: {
      executor: 'constant-vus',
      vus: 1,
      duration: '55m',
    },
  },
  thresholds: {
    // SLO gates -- test fails if these are breached
    'http_req_failed':        ['rate<0.05'],   // error rate < 5%
    'http_req_duration':      ['p(95)<3000'],  // p95 response time < 3s
    'dt_page_load_ms':     ['p(95)<3000'],
  },
};

// Destination cities -- mapped to DT portfolio/market names in the narrative
const DESTINATIONS = [
  'Paris', 'Sydney', 'London', 'New York', 'Tokyo',
  'Singapore', 'Dubai', 'Melbourne', 'Hong Kong', 'Zurich',
];

function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

// ── Main virtual user journey ─────────────────────────────────────────────────
export default function () {
  const params = {
    headers: { 'Accept': 'text/html,application/xhtml+xml' },
    timeout: '15s',
  };

  // ── Step 1: Load Adviser Portal homepage ─────────────────────────────────
  group('01_homepage', () => {
    const res = http.get(`${BASE_URL}/`, params);
    check(res, {
      'homepage 200': (r) => r.status === 200,
      'homepage has content': (r) => r.body && r.body.includes('easytravel'),
    });
    errorRate.add(res.status !== 200);
    pageLoadTime.add(res.timings.duration);
    if (res.status === 200) successfulLoads.add(1);
    sleep(1 + Math.random() * 2);
  });

  // ── Step 2: Browse special offers (featured investment products) ──────────
  group('02_special_offers', () => {
    const res = http.get(`${BASE_URL}/special-offers.jsp`, params);
    check(res, {
      'special offers 200': (r) => r.status === 200,
    });
    errorRate.add(res.status !== 200);
    pageLoadTime.add(res.timings.duration);
    sleep(1 + Math.random() * 2);
  });

  // ── Step 3: View main portal (search / portfolio browse) ─────────────────
  group('03_portal', () => {
    const res = http.get(`${BASE_URL}/orange.jsf`, params);
    check(res, {
      'portal 200': (r) => r.status === 200,
    });
    errorRate.add(res.status !== 200);
    pageLoadTime.add(res.timings.duration);
    sleep(1 + Math.random() * 2);
  });

  // ── Step 4: Hit backend API (trade engine health check) ───────────────────
  // Port 8091 = backend Axis2 / trade execution engine
  group('04_backend_api', () => {
    const res = http.get(`${BASE_URL}:8091/`, { timeout: '10s' });
    check(res, {
      'backend reachable': (r) => r.status === 200 || r.status === 404,
    });
    errorRate.add(res.status >= 500);
    sleep(0.5 + Math.random());
  });

  // Think time between user interactions
  sleep(2 + Math.random() * 3);
}

export function handleSummary(data) {
  const errRate = ((data.metrics.http_req_failed?.values?.rate || 0) * 100).toFixed(2);
  const p95     = (data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(0);
  const rps     = (data.metrics.http_reqs?.values?.rate || 0).toFixed(2);
  const loads   = data.metrics.dt_successful_page_loads?.values?.count || 0;

  return {
    'k6/results/baseline-summary.json': JSON.stringify(data, null, 2),
    stdout: `
╔══════════════════════════════════════════════════╗
║   DT Baseline Test -- Results Summary         ║
╠══════════════════════════════════════════════════╣
║  Requests/s:     ${rps.padEnd(10)}                   ║
║  Error rate:     ${errRate}%                      ║
║  p95 latency:    ${p95}ms                          ║
║  Page loads:     ${loads.toString().padEnd(10)}                   ║
╚══════════════════════════════════════════════════╝
`,
  };
}
