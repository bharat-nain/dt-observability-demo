#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/bootstrap.sh — One-time setup of Terraform remote state backend
#
# Run this ONCE before `terraform init`. Creates:
#   - S3 bucket for Terraform state (versioned + encrypted)
#   - DynamoDB table for state locking (prevents concurrent applies)
#
# These resources are intentionally NOT managed by Terraform (chicken-and-egg).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-dt}"
AWS_REGION="ap-southeast-2"
STATE_BUCKET="dt-demo-tfstate"
LOCK_TABLE="dt-demo-tfstate-lock"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── S3 Bucket ─────────────────────────────────────────────────────────────────
info "Checking Terraform state bucket: ${STATE_BUCKET}"

if aws s3api head-bucket --bucket "${STATE_BUCKET}" --profile "${AWS_PROFILE}" 2>/dev/null; then
  warn "S3 bucket '${STATE_BUCKET}' already exists — skipping creation"
else
  info "Creating S3 bucket in ${AWS_REGION}..."
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
    --profile "${AWS_PROFILE}"
  success "S3 bucket created"
fi

info "Enabling versioning on state bucket..."
aws s3api put-bucket-versioning \
  --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled \
  --profile "${AWS_PROFILE}"
success "Versioning enabled"

info "Enabling AES-256 encryption on state bucket..."
aws s3api put-bucket-encryption \
  --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }' \
  --profile "${AWS_PROFILE}"
success "Encryption enabled"

info "Blocking public access on state bucket..."
aws s3api put-public-access-block \
  --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' \
  --profile "${AWS_PROFILE}"
success "Public access blocked"

# ── DynamoDB Lock Table ───────────────────────────────────────────────────────
info "Checking DynamoDB lock table: ${LOCK_TABLE}"

if aws dynamodb describe-table \
     --table-name "${LOCK_TABLE}" \
     --region "${AWS_REGION}" \
     --profile "${AWS_PROFILE}" > /dev/null 2>&1; then
  warn "DynamoDB table '${LOCK_TABLE}' already exists — skipping creation"
else
  info "Creating DynamoDB table for state locking..."
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}"

  info "Waiting for table to become active..."
  aws dynamodb wait table-exists \
    --table-name "${LOCK_TABLE}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}"
  success "DynamoDB lock table ready"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Terraform backend ready!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  S3 bucket:   s3://${STATE_BUCKET}"
echo -e "  DynamoDB:    ${LOCK_TABLE}"
echo ""
echo -e "  Next: run ${YELLOW}make init${NC}"
echo ""
