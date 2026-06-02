# ─────────────────────────────────────────────────────────────────────────────
# DT Observability Demo — Makefile
#
# Full lifecycle management in one place.
# Prerequisites: terraform, ansible, ansible-galaxy, k6, aws-cli, jq, curl
# ─────────────────────────────────────────────────────────────────────────────

# Load .env if present (local overrides for DT_API_TOKEN etc.)
-include .env

# Required env vars — export these before running
DT_API_TOKEN  ?= $(error "DT_API_TOKEN is not set. Export it or add to .env")
DT_ENV_ID     ?= zwc56698
AWS_PROFILE   ?= dt
APP_HOST      ?= $(shell cd terraform && terraform output -raw instance_public_ip 2>/dev/null || echo "localhost")

TERRAFORM_DIR := terraform
ANSIBLE_DIR   := ansible
DT_DIR        := dynatrace
K6_DIR        := k6

.PHONY: help bootstrap init plan up provision provision-app provision-agent restart dashboards \
        baseline spike stress soak soak-short status down \
        vault-encrypt vault-decrypt ansible-deps check-deps

# ── Default target ─────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo ""
	@echo "  DT Observability Demo"
	@echo "  ─────────────────────────────────────────────────────────"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Quickstart:  make bootstrap → make init → make up → make baseline"
	@echo ""

# ── One-time setup ─────────────────────────────────────────────────────────────
bootstrap: check-deps ## [ONCE] Create S3 bucket + DynamoDB for Terraform state
	@echo ">>> Creating Terraform state backend..."
	@bash scripts/bootstrap.sh

init: check-deps ## [ONCE] Initialise Terraform and install Ansible collections
	@echo ">>> Initialising Terraform..."
	@cd $(TERRAFORM_DIR) && terraform init
	@echo ">>> Installing Ansible collections..."
	@cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml
	@echo ">>> Done. Next: copy terraform/terraform.tfvars.example → terraform/terraform.tfvars"

# ── Infrastructure ─────────────────────────────────────────────────────────────
plan: ## Show Terraform execution plan (no changes made)
	@cd $(TERRAFORM_DIR) && terraform plan

up: ## FULL STACK: terraform apply + ansible provision + push DT configs
	@bash scripts/up.sh

provision: ## Re-run Ansible only (skip Terraform — instance must already exist)
	@echo ">>> Re-provisioning with Ansible..."
	@cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml \
	  -i inventory/hosts.ini \
	  --vault-password-file ../.vault_pass \
	  -v

provision-app: ## Re-deploy EasyTravel only (fastest re-deploy)
	@echo ">>> Re-deploying EasyTravel..."
	@cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml \
	  -i inventory/hosts.ini \
	  --vault-password-file ../.vault_pass \
	  --tags easytravel -v

restart: ## Restart EasyTravel containers in-place (no re-provision, ~30s)
	@echo ">>> Restarting EasyTravel containers on $(APP_HOST)..."
	@ssh -i .ssh/dt-demo.pem ubuntu@$(APP_HOST) \
	  "cd /opt/easytravel && docker compose restart"
	@echo ">>> Done. JVM needs ~30s to warm up."
	@echo ">>> Check: make status"

provision-agent: ## Re-install Dynatrace OneAgent only
	@echo ">>> Re-installing Dynatrace OneAgent..."
	@cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml \
	  -i inventory/hosts.ini \
	  --vault-password-file ../.vault_pass \
	  --tags dynatrace_agent -v

# ── Dynatrace Config ───────────────────────────────────────────────────────────
dashboards: ## Push all Dynatrace configs (dashboards, SLOs, alerts, MZ)
	@echo ">>> Deploying Dynatrace observability configs..."
	@DT_API_TOKEN=$(DT_API_TOKEN) DT_ENV_ID=$(DT_ENV_ID) bash $(DT_DIR)/deploy.sh

# ── Load Tests ─────────────────────────────────────────────────────────────────
baseline: ## k6 baseline: 20 VUs, 5 min — normal trading day
	@echo ">>> Starting baseline load test against http://$(APP_HOST)"
	@mkdir -p k6/results
	@k6 run $(K6_DIR)/scenarios/baseline.js -e APP_HOST=$(APP_HOST)

spike: ## k6 spike: ramp to 150 VUs — DEMO MOMENT (triggers Davis AI)
	@echo ">>> Starting SPIKE test — watch Dynatrace for Davis AI problems!"
	@echo ">>> Dynatrace: https://$(DT_ENV_ID).live.dynatrace.com/ui/problems"
	@mkdir -p k6/results
	@k6 run $(K6_DIR)/scenarios/spike.js -e APP_HOST=$(APP_HOST)

stress: ## k6 stress: ramp to 200 VUs — find breaking point
	@echo ">>> Starting stress test (saturation)..."
	@mkdir -p k6/results
	@k6 run $(K6_DIR)/scenarios/stress.js -e APP_HOST=$(APP_HOST)

soak: ## k6 soak: 30 VUs for 30 min — expose memory leaks and latency drift
	@echo ">>> Starting soak test (30 min endurance run)..."
	@echo ">>> Watch Dynatrace SRE Dashboard -> JVM Heap and GC Suspension Time"
	@mkdir -p k6/results
	@k6 run $(K6_DIR)/scenarios/soak.js -e APP_HOST=$(APP_HOST)

soak-short: ## k6 soak (5 min demo-friendly version for interview)
	@echo ">>> Starting short soak test (5 min)..."
	@mkdir -p k6/results
	@k6 run $(K6_DIR)/scenarios/soak.js -e APP_HOST=$(APP_HOST) -e DURATION=5m

# ── Status ─────────────────────────────────────────────────────────────────────
status: ## Print instance info, service URLs, and live connectivity check
	@echo ""
	@echo "  Instance IP:  $(APP_HOST)"
	@echo "  EasyTravel:   http://$(APP_HOST)/"
	@echo "  Admin UI:     http://$(APP_HOST):8079/"
	@echo "  Dynatrace:    https://$(DT_ENV_ID).live.dynatrace.com"
	@echo "  SSH:          ssh -i .ssh/dt-demo.pem ubuntu@$(APP_HOST)"
	@echo ""
	@echo "  Connectivity:"
	@curl -sf --max-time 5 http://$(APP_HOST)/         >/dev/null \
	  && echo "  ✓  Portal (port 80)  — UP" \
	  || echo "  ✗  Portal (port 80)  — DOWN or unreachable"
	@curl -sf --max-time 5 http://$(APP_HOST):8079/    >/dev/null \
	  && echo "  ✓  Admin UI (8079)   — UP" \
	  || echo "  ✗  Admin UI (8079)   — DOWN or unreachable"
	@curl -sf --max-time 5 http://$(APP_HOST):8091/    >/dev/null \
	  && echo "  ✓  Backend API (8091)— UP" \
	  || echo "  ✗  Backend API (8091)— DOWN or unreachable"
	@echo ""
	@cd $(TERRAFORM_DIR) && terraform output 2>/dev/null || true

# ── Teardown ──────────────────────────────────────────────────────────────────
down: ## FULL TEARDOWN: stop app + destroy all AWS infrastructure
	@bash scripts/down.sh

# ── Ansible Vault helpers ──────────────────────────────────────────────────────
vault-encrypt: ## Encrypt ansible/vault/secrets.yml with ansible-vault
	@ansible-vault encrypt ansible/vault/secrets.yml --vault-password-file .vault_pass

vault-decrypt: ## Decrypt ansible/vault/secrets.yml for editing
	@ansible-vault decrypt ansible/vault/secrets.yml --vault-password-file .vault_pass

# ── Dependency check ───────────────────────────────────────────────────────────
ansible-deps: ## Install Ansible Python dependencies (boto3 for dynamic inventory)
	@pip3 install boto3 botocore --quiet
	@cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

check-deps: ## Verify required tools are installed
	@echo "Checking dependencies..."
	@command -v terraform  >/dev/null 2>&1 || (echo "ERROR: terraform not found"  && exit 1)
	@command -v ansible    >/dev/null 2>&1 || (echo "ERROR: ansible not found"    && exit 1)
	@command -v aws        >/dev/null 2>&1 || (echo "ERROR: aws-cli not found"    && exit 1)
	@command -v k6         >/dev/null 2>&1 || (echo "ERROR: k6 not found — install from https://k6.io/docs/getting-started/installation/" && exit 1)
	@command -v jq         >/dev/null 2>&1 || (echo "ERROR: jq not found"         && exit 1)
	@command -v curl       >/dev/null 2>&1 || (echo "ERROR: curl not found"       && exit 1)
	@echo "All dependencies found."
