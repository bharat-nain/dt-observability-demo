#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/up.sh — Full stack bring-up
#
# Orchestrates the complete provisioning pipeline:
#   1. terraform apply   — creates AWS infra
#   2. Write Ansible inventory from TF output
#   3. Wait for SSH readiness
#   4. ansible-playbook  — configure OS, install Docker + DT agent, deploy app
#   5. dynatrace/deploy.sh — push dashboards, SLOs, alerts
#   6. Print access summary
#
# Prerequisites (run once):
#   - scripts/bootstrap.sh  (creates S3 bucket + DynamoDB)
#   - make init             (terraform init)
#   - Copy terraform/terraform.tfvars.example → terraform/terraform.tfvars
#   - Copy ansible/vault/secrets.yml.example → ansible/vault/secrets.yml
#   - Encrypt: ansible-vault encrypt ansible/vault/secrets.yml
#   - echo "your-vault-pass" > .vault_pass && chmod 600 .vault_pass
#   - Set DT_API_TOKEN env var (or export from vault)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
error()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Running pre-flight checks..."

[[ -f "terraform/terraform.tfvars" ]] || {
  error "terraform/terraform.tfvars not found. Copy from terraform.tfvars.example and fill in."
  exit 1
}

[[ -f "ansible/vault/secrets.yml" ]] || {
  error "ansible/vault/secrets.yml not found. Copy from secrets.yml.example, fill in, and encrypt with ansible-vault."
  exit 1
}

[[ -f ".vault_pass" ]] || {
  error ".vault_pass not found. Create with: echo 'your-password' > .vault_pass && chmod 600 .vault_pass"
  exit 1
}

[[ -n "${DT_API_TOKEN:-}" ]] || {
  error "DT_API_TOKEN environment variable is not set. Export your Dynatrace API token."
  exit 1
}

[[ -n "${DT_ENV_ID:-}" ]] || export DT_ENV_ID="zwc56698"

success "Pre-flight checks passed"

# ── Step 1: Terraform Apply ───────────────────────────────────────────────────
info "Step 1/5 — Applying Terraform (creating AWS infrastructure)..."
cd terraform
terraform apply -auto-approve
INSTANCE_IP=$(terraform output -raw instance_public_ip)
INSTANCE_ID=$(terraform output -raw instance_id)
cd ..
success "Infrastructure ready — instance IP: ${INSTANCE_IP}"

# ── Step 2: Write Ansible Inventory ──────────────────────────────────────────
info "Step 2/5 — Writing Ansible inventory..."
mkdir -p .ssh
# Dynamic inventory (aws_ec2.yml) auto-discovers by tag — static fallback:
cat > ansible/inventory/hosts.ini <<EOF
[all]
dt-demo ansible_host=${INSTANCE_IP} ansible_user=ubuntu ansible_ssh_private_key_file=../.ssh/dt-demo.pem

[role_observability_demo]
dt-demo
EOF
success "Inventory written"

# ── Step 3: Wait for SSH ──────────────────────────────────────────────────────
info "Step 3/5 — Waiting for SSH to become available (max 5 min)..."
MAX_ATTEMPTS=30
ATTEMPT=0
until ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=5 \
           -i .ssh/dt-demo.pem \
           ubuntu@"${INSTANCE_IP}" \
           "cloud-init status --wait" 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [[ ${ATTEMPT} -ge ${MAX_ATTEMPTS} ]]; then
    error "SSH not available after ${MAX_ATTEMPTS} attempts. Check instance ${INSTANCE_ID} in AWS console."
    exit 1
  fi
  info "Waiting for SSH... attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
  sleep 10
done
success "SSH ready + cloud-init complete"

# ── Step 4: Ansible Provisioning ─────────────────────────────────────────────
info "Step 4/5 — Running Ansible provisioning (this takes ~5 minutes)..."
cd ansible
ansible-playbook playbooks/site.yml \
  -i inventory/hosts.ini \
  --vault-password-file ../.vault_pass \
  -v
cd ..
success "Ansible provisioning complete"

# ── Step 5: Dynatrace Config Push ─────────────────────────────────────────────
info "Step 5/5 — Pushing Dynatrace observability configs..."
bash dynatrace/deploy.sh
success "Dynatrace configuration deployed"

# ── Final Summary ─────────────────────────────────────────────────────────────
DT_URL="https://${DT_ENV_ID}.live.dynatrace.com"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} DT Observability Demo — FULLY OPERATIONAL${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  APP (Adviser Portal):  ${BLUE}http://${INSTANCE_IP}/${NC}"
echo -e "  APP (B2B Portal):      ${BLUE}http://${INSTANCE_IP}:8093/${NC}"
echo -e "  APP (Admin/Problems):  ${BLUE}http://${INSTANCE_IP}:8079/${NC}"
echo ""
echo -e "  Dynatrace Tenant:      ${BLUE}${DT_URL}${NC}"
echo -e "  Business Dashboard:    ${BLUE}${DT_URL}/ui/dashboards${NC}"
echo -e "  SLOs:                  ${BLUE}${DT_URL}/ui/slo${NC}"
echo ""
echo -e "  Load tests:"
echo -e "    ${YELLOW}make baseline${NC}  — normal trading day (20 VUs, 5 min)"
echo -e "    ${YELLOW}make spike${NC}     — market event spike (150 VUs peak) ← DEMO MOMENT"
echo -e "    ${YELLOW}make stress${NC}    — saturation test"
echo ""
echo -e "  Teardown: ${YELLOW}make down${NC}"
echo ""
