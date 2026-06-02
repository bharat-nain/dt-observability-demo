/**
 * k6 Stress Test -- Saturation / Breaking Point
 *
 * Slowly ramps load until the platform saturates or errors spike.
 * Shows the interviewer: capacity planning, JVM heap limits,
 * and where the SLO budget gets exhausted.
 *
 * Usage:
 *   k6 run k6/scenarios/stress.js -e APP_HOST=<instance-ip>
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('dt_error_rate');

const APP_HOST = __ENV.APP_HOST || 'localhost';
const BASE_URL  = `http://${APP_HOST}`;

export const options = {
  scenarios: {
    ramp_to_saturation: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        { duration: '1m', target: 10  },
        { duration: '1m', target: 30  },
        { duration: '1m', target: 60  },
        { duration: '1m', target: 100 },
        { duration: '1m', target: 150 },
        { duration: '1m', target: 200 },
        { duration: '1m', target: 5   },   // Recovery
      ],
    },
  },
  thresholds: {
    'http_req_failed':   ['rate<0.20'],    // Allow up to 20% errors (stress test)
    'http_req_duration': ['p(99)<15000'],  // 99th percentile under 15s
  },
};

export default function () {
  // Batch two requests per VU iteration to increase throughput
  const responses = http.batch([
    ['GET', `${BASE_URL}/`,                  null, { timeout: '20s' }],
    ['GET', `${BASE_URL}/special-offers.jsp`, null, { timeout: '20s' }],
  ]);

  responses.forEach((res) => {
    check(res, { 'request ok': (r) => r.status < 500 });
    errorRate.add(res.status >= 500);
  });

  sleep(0.5 + Math.random());
}

export function handleSummary(data) {
  return {
    'k6/results/stress-summary.json': JSON.stringify(data, null, 2),
    stdout: `
╔══════════════════════════════════════════════════════════════════╗
║   DT Stress Test -- Saturation Results                        ║
╠══════════════════════════════════════════════════════════════════╣
║  Max req/s:   ${(data.metrics.http_reqs?.values?.rate || 0).toFixed(2).padEnd(12)}                               ║
║  Error rate:  ${((data.metrics.http_req_failed?.values?.rate || 0) * 100).toFixed(2)}%                                 ║
║  p95:         ${(data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(0)}ms                                 ║
║  p99:         ${(data.metrics.http_req_duration?.values?.['p(99)'] || 0).toFixed(0)}ms                                 ║
║                                                                  ║
║  Check SRE Dashboard for JVM heap and CPU saturation.            ║
╚══════════════════════════════════════════════════════════════════╝
`,
  };
}
