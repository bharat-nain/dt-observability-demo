/**
 * k6 Spike Test -- DT Market Event Simulation
 *
 * Simulates a sudden market event (RBA rate decision, ASX open, flash crash)
 * causing a 10x traffic surge. This is the KEY DEMO scenario -- run it
 * during the interview to show Davis AI detecting the anomaly in real time.
 *
 * Pattern:
 *   0-30s    ->  5 VUs  (quiet before the storm)
 *   30-60s   ->  ramp to 150 VUs  (market event hits)
 *   60-3m    ->  hold 150 VUs     (sustained pressure)
 *   3m-3m30s ->  drop to 5 VUs   (market calms)
 *   3m30s-5m ->  hold 5 VUs      (recovery observation)
 *
 * Watch in Dynatrace WHILE THIS RUNS:
 *   - Services view: request rate spike on all services
 *   - Davis AI Problems tab: auto-raised problem within ~2-3 min
 *   - SRE Dashboard: p95 latency breaches 3s SLO threshold
 *   - JVM heap pressure on SRE dashboard
 *
 * Usage:
 *   k6 run k6/scenarios/spike.js -e APP_HOST=<instance-ip>
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const errorRate   = new Rate('dt_error_rate');
const pageLatency = new Trend('dt_page_latency_ms', true);

const APP_HOST = __ENV.APP_HOST || 'localhost';
const BASE_URL  = `http://${APP_HOST}`;

export const options = {
  scenarios: {
    market_event_spike: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '30s', target: 5   },   // Quiet -- normal trading
        { duration: '30s', target: 150 },   // Spike -- market event hits
        { duration: '2m',  target: 150 },   // Sustained surge
        { duration: '30s', target: 5   },   // Recovery ramp-down
        { duration: '1m',  target: 5   },   // Recovery observation
      ],
      gracefulRampDown: '30s',
    },
  },
  // No thresholds -- spike test SHOULD breach SLOs. We WANT Davis AI to fire.
};

export default function () {
  const params = { timeout: '15s' };

  // All spike users hammer the main portal -- minimal think time
  group('homepage', () => {
    const res = http.get(`${BASE_URL}/`, params);
    check(res, { 'homepage ok': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    pageLatency.add(res.timings.duration);
  });

  group('portal', () => {
    const res = http.get(`${BASE_URL}/orange.jsf`, params);
    check(res, { 'portal ok': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    pageLatency.add(res.timings.duration);
  });

  group('special_offers', () => {
    const res = http.get(`${BASE_URL}/special-offers.jsp`, params);
    check(res, { 'offers ok': (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
  });

  // Minimal think time during spike -- high pressure
  sleep(0.1 + Math.random() * 0.3);
}

export function handleSummary(data) {
  const errRate = ((data.metrics.http_req_failed?.values?.rate || 0) * 100).toFixed(2);
  const p95     = (data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(0);
  const peakRps = (data.metrics.http_reqs?.values?.rate || 0).toFixed(2);

  return {
    'k6/results/spike-summary.json': JSON.stringify(data, null, 2),
    stdout: `
╔══════════════════════════════════════════════════╗
║   DT Spike Test -- Market Event Results       ║
╠══════════════════════════════════════════════════╣
║  Peak req/s:     ${peakRps.padEnd(10)}                   ║
║  Error rate:     ${errRate}%                      ║
║  p95 latency:    ${p95}ms                          ║
║                                                  ║
║  Check Dynatrace -> Problems for Davis AI alert! ║
╚══════════════════════════════════════════════════╝
`,
  };
}
