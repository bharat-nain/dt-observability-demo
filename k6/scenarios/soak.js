/**
 * k6 Soak Test -- DT Platform Endurance / Long-Duration Run
 *
 * Runs sustained moderate load for 30 minutes to expose issues that only
 * surface over time and are invisible in short spike or stress tests:
 *
 *   - JVM heap creep / memory leaks (visible in Dynatrace JVM tiles)
 *   - MongoDB connection pool exhaustion
 *   - Thread pool saturation (gradual latency drift)
 *   - Garbage collection pressure building over time
 *   - Disk fill from log rotation failures
 *
 * Pattern:
 *   0-3m    -> ramp from 0 to 30 VUs  (warm up JVM, fill caches)
 *   3m-27m  -> hold 30 VUs            (sustained production-like load)
 *   27m-30m -> ramp down to 0         (observe recovery behaviour)
 *
 * 30 VUs chosen deliberately -- heavy enough to stress the JVM over time
 * but not so heavy that it causes immediate saturation (that is spike/stress).
 *
 * INTERVIEW TALKING POINT:
 * "Soak tests catch an entire class of bugs that escape all other test types.
 *  A service that handles 10k req/s for 30 seconds often fails silently at
 *  3k req/s over 30 minutes due to resource leaks. This is what brought down
 *  a wealth platform during month-end reporting -- not peak load but sustained
 *  mid-tier load over hours."
 *
 * Dynatrace panels to watch:
 *   SRE Dashboard -> JVM Heap Used (should stay flat, not climb)
 *   SRE Dashboard -> GC Suspension Time (should not trend upward)
 *   SRE Dashboard -> Response Time p95 (should stay stable, not drift)
 *   SRE Dashboard -> DB Call Duration (connection pool health)
 *   Host panel    -> CPU (sustained ~40-60% is healthy; climbing = leak)
 *
 * Usage:
 *   k6 run k6/scenarios/soak.js -e APP_HOST=<instance-ip>
 *
 * For a shorter demo run (5 min instead of 30), pass:
 *   k6 run k6/scenarios/soak.js -e APP_HOST=<ip> -e DURATION=5m
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Custom metrics ─────────────────────────────────────────────────────────
const errorRate          = new Rate('dt_error_rate');
const pageLoadTime       = new Trend('dt_page_load_ms', true);
const totalRequests      = new Counter('dt_total_requests');
const degradedResponses  = new Counter('dt_degraded_responses'); // p95 > 2s

// ── Config ─────────────────────────────────────────────────────────────────
const APP_HOST = __ENV.APP_HOST || 'localhost';
const BASE_URL  = `http://${APP_HOST}`;
const DURATION  = __ENV.DURATION  || '30m';

// Parse duration string to seconds for stage calculation
function durationToSeconds(d) {
  if (d.endsWith('m')) return parseInt(d) * 60;
  if (d.endsWith('h')) return parseInt(d) * 3600;
  if (d.endsWith('s')) return parseInt(d);
  return 1800; // default 30m
}

const totalSec   = durationToSeconds(DURATION);
const rampSec    = Math.min(180, Math.floor(totalSec * 0.1)); // 10% ramp, max 3m
const holdSec    = totalSec - rampSec * 2;
const rampStr    = `${rampSec}s`;
const holdStr    = `${holdSec}s`;

export const options = {
  scenarios: {
    endurance_run: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampStr, target: 30 },   // Warm-up ramp
        { duration: holdStr, target: 30 },   // Sustained load
        { duration: rampStr, target: 0  },   // Ramp-down + recovery observation
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    // Tighter thresholds than spike/stress -- soak should not degrade
    'http_req_failed':     ['rate<0.02'],          // <2% error rate throughout
    'http_req_duration':   ['p(95)<3000', 'p(99)<8000'],
    'dt_page_load_ms':  ['p(95)<3000'],
  },
};

// Pages to cycle through -- varied to exercise different code paths
// and prevent JVM bytecode compilation from masking real performance
const PAGES = [
  { name: 'homepage',       url: '/' },
  { name: 'portal',         url: '/orange.jsf' },
  { name: 'special_offers', url: '/special-offers.jsp' },
  { name: 'about',          url: '/about-orange.jsf' },
  { name: 'contact',        url: '/contact-orange.jsf' },
];

let pageIndex = 0;

export default function () {
  // Cycle through pages in round-robin so all code paths stay warm
  const page = PAGES[(__VU + __ITER) % PAGES.length];

  const params = {
    headers: { 'Accept': 'text/html,application/xhtml+xml' },
    timeout: '20s',
    tags: { page: page.name },   // Tag each request for Dynatrace correlation
  };

  group(page.name, () => {
    const res = http.get(`${BASE_URL}${page.url}`, params);

    const ok = check(res, {
      [`${page.name} status 200`]: (r) => r.status === 200,
      [`${page.name} has body`]:   (r) => r.body && r.body.length > 100,
    });

    errorRate.add(res.status !== 200);
    pageLoadTime.add(res.timings.duration);
    totalRequests.add(1);

    // Track degraded responses (latency > 2s is a sign of slow resource leak)
    if (res.timings.duration > 2000) {
      degradedResponses.add(1);
    }
  });

  // Realistic think time -- varied to prevent thundering herd patterns
  sleep(2 + Math.random() * 4);
}

export function handleSummary(data) {
  const errRate    = ((data.metrics.http_req_failed?.values?.rate    || 0) * 100).toFixed(2);
  const p50        = (data.metrics.http_req_duration?.values?.['p(50)'] || 0).toFixed(0);
  const p95        = (data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(0);
  const p99        = (data.metrics.http_req_duration?.values?.['p(99)'] || 0).toFixed(0);
  const rps        = (data.metrics.http_reqs?.values?.rate            || 0).toFixed(2);
  const total      = data.metrics.dt_total_requests?.values?.count || 0;
  const degraded   = data.metrics.dt_degraded_responses?.values?.count || 0;
  const degradedPct = total > 0 ? ((degraded / total) * 100).toFixed(1) : '0.0';

  return {
    'k6/results/soak-summary.json': JSON.stringify(data, null, 2),
    stdout: `
╔══════════════════════════════════════════════════════════════════════╗
║   DT Soak Test -- Endurance Results (${DURATION} run)
╠══════════════════════════════════════════════════════════════════════╣
║  Avg req/s:       ${rps.padEnd(12)}                                  ║
║  Total requests:  ${total.toString().padEnd(12)}                     ║
║  Error rate:      ${errRate}%                                        ║
║                                                                      ║
║  Latency percentiles:                                                ║
║    p50:  ${p50}ms                                                    ║
║    p95:  ${p95}ms  (SLO threshold: 3000ms)                          ║
║    p99:  ${p99}ms                                                    ║
║                                                                      ║
║  Degraded responses (>2s): ${degraded} (${degradedPct}% of total)   ║
║                                                                      ║
║  Check Dynatrace SRE Dashboard for:                                  ║
║    - JVM heap trend (should be flat, not climbing)                   ║
║    - GC pause time trend (should not increase over time)             ║
║    - Response time drift (p95 start vs end of run)                   ║
╚══════════════════════════════════════════════════════════════════════╝
`,
  };
}
