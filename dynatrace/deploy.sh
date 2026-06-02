#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dynatrace/deploy.sh — Push all observability configs to Dynatrace via API
#
# Targets a Dynatrace Grail/Platform tenant (2024+):
#   - Settings API v2   (live.dynatrace.com) for ownership teams + anomaly detection
#   - SLO API v2        (live.dynatrace.com) for SLOs
#   - Document API v1   (apps.dynatrace.com) for dashboards
#
# NOTE: Classic schemas (builtin:management-zones, builtin:anomaly-detection.metric-events)
# are NOT available on Grail tenants. Grail equivalents used here:
#   builtin:ownership.teams              (replaces management zones)
#   builtin:anomaly-detection.services   (configures Davis AI thresholds directly)
#
# Required token scopes:
#   settings.read   settings.write   slo.read   slo.write
#   document:documents:read   document:documents:write
#
# Usage:
#   export DT_API_TOKEN="dt0c01.xxxx"
#   export DT_ENV_ID="zwc56698"
#   ./dynatrace/deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DT_ENV_ID="${DT_ENV_ID:?'DT_ENV_ID is required'}"
DT_API_TOKEN="${DT_API_TOKEN:?'DT_API_TOKEN is required'}"

DT_LIVE_URL="https://${DT_ENV_ID}.live.dynatrace.com"
DT_APPS_URL="https://${DT_ENV_ID}.apps.dynatrace.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── HTTP helpers — no -f flag, never trigger set -e ──────────────────────────
live_get()  { curl -s -H "Authorization: Api-Token ${DT_API_TOKEN}" -H "Content-Type: application/json" "${DT_LIVE_URL}${1}"; }
live_post() { curl -s -X POST -H "Authorization: Api-Token ${DT_API_TOKEN}" -H "Content-Type: application/json" -d "${2}" "${DT_LIVE_URL}${1}"; }
live_put()  { curl -s -X PUT  -H "Authorization: Api-Token ${DT_API_TOKEN}" -H "Content-Type: application/json" -d "${2}" "${DT_LIVE_URL}${1}"; }
apps_get()  { curl -s -H "Authorization: Api-Token ${DT_API_TOKEN}" -H "Content-Type: application/json" "${DT_APPS_URL}${1}"; }

http_status() {
  curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Api-Token ${DT_API_TOKEN}" \
    -H "Content-Type: application/json" "${1}"
}

# ── Validate connectivity ─────────────────────────────────────────────────────
info "Validating connection to ${DT_LIVE_URL}"
STATUS=$(http_status "${DT_LIVE_URL}/api/v2/settings/schemas")
case "${STATUS}" in
  200) success "Connected (HTTP ${STATUS})" ;;
  401) error "HTTP 401 — token invalid. Check DT_API_TOKEN."; exit 1 ;;
  403) error "HTTP 403 — token missing scopes. Need: settings.read settings.write slo.read slo.write document:documents:read document:documents:write"; exit 1 ;;
  *)   error "HTTP ${STATUS} — unexpected response. Check DT_ENV_ID."; exit 1 ;;
esac

# ── Step 1: Ownership Team (Settings API v2) ──────────────────────────────────
# builtin:management-zones is not available on Grail. builtin:ownership.teams is
# the Grail-native equivalent: groups entities by team responsibility.
info "Step 1/4 — Ownership Team (builtin:ownership.teams)"

TEAM_IDENTIFIER="dt-platform-engineering"
EXISTING_TEAM=$(live_get "/api/v2/settings/objects?schemaIds=builtin:ownership.teams&scopes=environment" \
  | jq -r --arg id "${TEAM_IDENTIFIER}" \
    '.items[] | select(.value.identifier == $id) | .objectId' 2>/dev/null || true)

if [[ -n "${EXISTING_TEAM}" ]]; then
  warn "Ownership team '${TEAM_IDENTIFIER}' already exists — skipping"
else
  TEAM_PAYLOAD='[{
    "schemaId": "builtin:ownership.teams",
    "scope": "environment",
    "value": {
      "name": "DT Platform Engineering",
      "identifier": "dt-platform-engineering",
      "description": "Platform Engineering team responsible for DT wealth management platform. Owns the trade engine, adviser portal, and all host-level infrastructure.",
      "responsibilities": {
        "operations": true,
        "infrastructure": true,
        "development": false,
        "security": false,
        "lineOfBusiness": false
      },
      "contactDetails": []
    }
  }]'

  TEAM_RESULT=$(live_post "/api/v2/settings/objects" "${TEAM_PAYLOAD}")
  TEAM_OBJ=$(echo "${TEAM_RESULT}" | jq -r '.[0].objectId // empty' 2>/dev/null || true)
  if [[ -n "${TEAM_OBJ}" ]]; then
    success "Ownership team 'DT Platform Engineering' created"
  else
    warn "Ownership team: $(echo "${TEAM_RESULT}" | jq -r '.[0].error.message // "unknown error"' 2>/dev/null || true)"
  fi
fi

# ── Step 2: SLOs (SLO API v2) ─────────────────────────────────────────────────
info "Step 2/4 — SLOs (SLO API v2)"

# Fetch the full SLO list once, then loop
SLO_LIST=$(live_get "/api/v2/slo?pageSize=500")
SLO_SCOPE_MISSING=false

while IFS= read -r slo; do
  # Abort remaining SLOs once we know the scope is unavailable on this tenant
  if [[ "${SLO_SCOPE_MISSING}" == "true" ]]; then
    break
  fi

  SLO_NAME=$(echo "${slo}" | jq -r '.name')

  # Use --arg so jq handles the em-dash and parens in the name safely
  EXISTING=$(echo "${SLO_LIST}" \
    | jq -r --arg n "${SLO_NAME}" '.slo[] | select(.name == $n) | .id' 2>/dev/null || true)

  if [[ -n "${EXISTING}" ]]; then
    warn "SLO '${SLO_NAME}' already exists (${EXISTING}) — skipping"
  else
    RESULT=$(live_post "/api/v2/slo" "${slo}")
    SLO_ID=$(echo "${RESULT}" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -n "${SLO_ID}" ]]; then
      success "SLO created: '${SLO_NAME}' (${SLO_ID})"
    else
      ERR=$(echo "${RESULT}" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null || true)
      if [[ "${ERR}" == *"slo.write"* || "${ERR}" == *"missing required scope"* ]]; then
        warn "SLO API write access not available via API token on this Platform tenant."
        warn "  The 'slo.write' scope requires OAuth2 on Grail tenants — create SLOs manually:"
        warn "  1. Go to: ${DT_LIVE_URL}/ui/slo"
        warn "  2. Click 'New SLO' and add the three SLOs from: dynatrace/slos/platform_slos.json"
        SLO_SCOPE_MISSING=true
      else
        warn "SLO '${SLO_NAME}': ${ERR}"
      fi
    fi
  fi
done < <(jq -c '.[]' "${SCRIPT_DIR}/slos/platform_slos.json")

# ── Step 3: Service Anomaly Detection (Settings API v2) ───────────────────────
# builtin:anomaly-detection.metric-events is not available on Grail.
# builtin:anomaly-detection.services configures Davis AI detection thresholds:
#   - failureRate.threshold = 5%      Alert when service error rate exceeds 5%
#   - responseTime degradation 500ms  Alert when p50 response time jumps 500ms
#   - overAlertingProtection          Suppress noise below 10 req/min
info "Step 3/4 — Service Anomaly Detection (builtin:anomaly-detection.services)"

# Single-object schema — check for an existing object to decide POST vs PUT
ANOMALY_EXISTING=$(live_get "/api/v2/settings/objects?schemaIds=builtin:anomaly-detection.services&scopes=environment" \
  | jq -r '.items[0].objectId // empty' 2>/dev/null || true)

ANOMALY_PAYLOAD='[{
  "schemaId": "builtin:anomaly-detection.services",
  "scope": "environment",
  "value": {
    "failureRate": {
      "enabled": true,
      "detectionMode": "fixed",
      "fixedDetection": {
        "threshold": 5,
        "sensitivity": "medium",
        "overAlertingProtection": {
          "minutesAbnormalState": 1,
          "requestsPerMinute": 10
        }
      }
    },
    "responseTime": {
      "enabled": true,
      "detectionMode": "fixed",
      "fixedDetection": {
        "responseTimeAll": { "degradationMilliseconds": 500 },
        "responseTimeSlowest": { "slowestDegradationMilliseconds": 1000 },
        "sensitivity": "medium",
        "overAlertingProtection": {
          "minutesAbnormalState": 5,
          "requestsPerMinute": 10
        }
      }
    },
    "loadSpikes": { "enabled": false },
    "loadDrops":  { "enabled": false }
  }
}]'

if [[ -n "${ANOMALY_EXISTING}" ]]; then
  # PUT to the existing objectId to update
  ANOMALY_RESULT=$(live_put "/api/v2/settings/objects/${ANOMALY_EXISTING}" \
    "$(echo "${ANOMALY_PAYLOAD}" | jq -c '.[0].value')")
  # Dynatrace Settings API PUT may return 200 with empty body — fall back to known objectId
  ANOMALY_OBJ=$(echo "${ANOMALY_RESULT}" | jq -r '.objectId // empty' 2>/dev/null || true)
  [[ -z "${ANOMALY_OBJ}" ]] && ANOMALY_OBJ="${ANOMALY_EXISTING}"
else
  ANOMALY_RESULT=$(live_post "/api/v2/settings/objects" "${ANOMALY_PAYLOAD}")
  ANOMALY_OBJ=$(echo "${ANOMALY_RESULT}" | jq -r '.[0].objectId // empty' 2>/dev/null || true)
fi

if [[ -n "${ANOMALY_OBJ}" ]]; then
  success "Service anomaly detection configured: error rate > 5%, response time degradation > 500ms"
else
  warn "Service anomaly detection: $(echo "${ANOMALY_RESULT}" | jq -r '.[0].error.message // .error.message // "see output above"' 2>/dev/null || true)"
fi

# ── Step 4: Dashboards (Document API v1 on apps domain) ───────────────────────
info "Step 4/4 — Dashboards (Document API)"

DASH_STATUS=$(http_status "${DT_APPS_URL}/platform/document/v1/documents?documentType=dashboard")

if [[ "${DASH_STATUS}" == "200" ]]; then
  for dash_file in "${SCRIPT_DIR}/dashboards/"*.json; do
    # Support both classic (.dashboardMetadata.name) and Grail (.name) format
    DASH_NAME=$(jq -r '.dashboardMetadata.name // .name' "${dash_file}")

    EXISTING_ID=$(apps_get "/platform/document/v1/documents?documentType=dashboard" \
      | jq -r --arg n "${DASH_NAME}" '.documents[] | select(.name == $n) | .id' 2>/dev/null || true)

    METADATA=$(jq -n --arg n "${DASH_NAME}" \
      '{"name": $n, "type": "dashboard", "isPrivate": false}')

    if [[ -n "${EXISTING_ID}" ]]; then
      warn "Dashboard '${DASH_NAME}' already exists (${EXISTING_ID}) — updating"
      RESULT=$(curl -s -X PUT \
        -H "Authorization: Api-Token ${DT_API_TOKEN}" \
        -F "metadata=${METADATA};type=application/json" \
        -F "content=@${dash_file};type=application/json" \
        "${DT_APPS_URL}/platform/document/v1/documents/${EXISTING_ID}")
    else
      RESULT=$(curl -s -X POST \
        -H "Authorization: Api-Token ${DT_API_TOKEN}" \
        -F "metadata=${METADATA};type=application/json" \
        -F "content=@${dash_file};type=application/json" \
        "${DT_APPS_URL}/platform/document/v1/documents")
    fi

    DOC_ID=$(echo "${RESULT}" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -n "${DOC_ID}" ]]; then
      success "Dashboard deployed: '${DASH_NAME}'"
    else
      warn "Dashboard '${DASH_NAME}': $(echo "${RESULT}" | jq -r '.error // .message // "check response above"' 2>/dev/null || true)"
    fi
  done
elif [[ "${DASH_STATUS}" == "401" || "${DASH_STATUS}" == "403" ]]; then
  warn "Dashboard Document API returned HTTP ${DASH_STATUS}."
  warn "On Grail/Platform tenants this API requires OAuth2 — API tokens cannot be used."
  warn ""
  warn "Manual upload takes ~2 minutes (already done? skip this):"
  warn "  1. Go to ${DT_APPS_URL}/ui/apps/dynatrace.dashboards"
  warn "  2. Click the Upload button (top-right)"
  warn "  3. Upload: dynatrace/dashboards/business_dashboard.json"
  warn "  4. Upload: dynatrace/dashboards/sre_dashboard.json"
else
  warn "Dashboard Document API returned HTTP ${DASH_STATUS} — skipping dashboard deployment"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Dynatrace configuration deployed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Tenant:        ${BLUE}${DT_LIVE_URL}${NC}"
echo -e "  Ownership:     ${BLUE}${DT_LIVE_URL}/ui/ownership${NC}"
echo -e "  SLOs:          ${BLUE}${DT_LIVE_URL}/ui/slo${NC}"
echo -e "  Problems:      ${BLUE}${DT_LIVE_URL}/ui/problems${NC}"
echo -e "  Dashboards:    ${BLUE}${DT_APPS_URL}/ui/apps/dynatrace.dashboards${NC}"
echo ""
