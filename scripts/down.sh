#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/down.sh — Teardown the entire demo environment
#
# Stops the application cleanly, then destroys all AWS infrastructure.
# The Dynatrace tenant config (dashboards, SLOs) is left in place by default
# since the trial account persists — pass --clean-dynatrace to remove it too.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $*"; }

CLEAN_DT=false
[[ "${1:-}" == "--clean-dynatrace" ]] && CLEAN_DT=true

# ── Confirm teardown ──────────────────────────────────────────────────────────
warn "This will DESTROY all AWS infrastructure for the dt-demo environment."
warn "Dynatrace dashboards/SLOs will be preserved (pass --clean-dynatrace to remove)."
echo ""
read -rp "  Type 'yes' to confirm: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Step 1: Stop application gracefully ──────────────────────────────────────
if [[ -f "ansible/inventory/hosts.ini" ]] && [[ -f ".vault_pass" ]]; then
  info "Step 1/2 — Running Ansible teardown (graceful app shutdown)..."
  cd ansible
  ansible-playbook playbooks/teardown.yml \
    -i inventory/hosts.ini \
    --vault-password-file ../.vault_pass 2>/dev/null || true
  cd ..
  success "Application stopped"
else
  warn "Skipping Ansible teardown (no inventory or vault pass found)"
fi

# ── Step 2: Terraform Destroy ─────────────────────────────────────────────────
info "Step 2/2 — Destroying AWS infrastructure (terraform destroy)..."
cd terraform
terraform destroy -auto-approve
cd ..
success "AWS infrastructure destroyed"

# ── Cleanup local artifacts ───────────────────────────────────────────────────
info "Cleaning up local artifacts..."
rm -f .ssh/dt-demo.pem
rm -f ansible/inventory/hosts.ini
success "Local artifacts cleaned"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Teardown complete. All AWS resources destroyed.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Dynatrace config preserved at: ${BLUE}https://zwc56698.live.dynatrace.com${NC}"
echo -e "  To bring everything back up:   ${YELLOW}make up${NC}"
echo ""
