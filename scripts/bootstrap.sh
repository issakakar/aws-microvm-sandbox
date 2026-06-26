#!/usr/bin/env bash
# scripts/bootstrap.sh — ordered first-time setup for microvm-bench.
#
# Run ONCE after cloning. Subsequent changes use individual make targets.
#
# Steps:
#   1. Terraform apply (global + both regions)
#   2. Register arm64 binfmt (for local docker cross-builds)
#   3. Build provisioner + reaper binaries (cross-compile arm64, zip)
#   4. Build microVM images in both regions (all 3 variants) — triggers AWS builds
#   5. Update provisioner Lambda env vars with real image ARNs
#   6. Deploy frontend
#
# Cost warning: steps 4-6 hit AWS; images take ~5-15 min each to build server-side.
# Total estimated first-run cost: < $0.50 (image build compute is free; storage + EBS minimal).
#
# Prerequisites:
#   - aws configure --profile microvm-bench (or creds in ~/.aws)
#   - AWS creds for the SPA deploy (S3 + CloudFront) — same profile as above
#   - terraform, go, cargo, docker, pnpm, jq all on PATH (see README.md)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Load .env if present (AWS profile, harness overrides, etc.)
if [[ -f .env ]]; then
  # Export non-comment, non-blank lines
  set -o allexport
  # shellcheck source=/dev/null
  source .env
  set +o allexport
fi

AWS_PROFILE="${AWS_PROFILE:-microvm-bench}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws --profile "${AWS_PROFILE}" sts get-caller-identity --query Account --output text)}"
REGIONS=("us-east-1" "us-west-2")
VARIANTS=("base" "mpl" "sci")

echo "========================================================"
echo "  microvm-bench first-time bootstrap"
echo "========================================================"
echo ""
echo "  AWS profile  : ${AWS_PROFILE}"
echo "  Account      : ${ACCOUNT_ID}"
echo "  Regions      : ${REGIONS[*]}"
echo "  Variants     : ${VARIANTS[*]}"
echo ""
echo "COST WARNING: This script will:"
echo "  - Create S3 buckets, IAM roles, Lambda functions (minimal cost)"
echo "  - Build 6 microVM images (3 variants x 2 regions) on Graviton"
echo "  - Deploy the SPA to S3 + CloudFront"
echo ""
echo "Press Enter to continue or Ctrl-C to abort."
read -r </dev/tty

# ---------------------------------------------------------------------------
# Step 1: Terraform apply
# ---------------------------------------------------------------------------
echo ""
echo "==[1/6]== Terraform apply (infra/) ..."
(cd infra && terraform init -input=false)
(cd infra && terraform apply -auto-approve -input=false)
echo "    Terraform apply complete."

# ---------------------------------------------------------------------------
# Step 2: Register arm64 binfmt (for local arm64 docker builds)
# ---------------------------------------------------------------------------
echo ""
echo "==[2/6]== Registering arm64 binfmt (docker qemu) ..."
make binfmt
echo "    binfmt registered."

# ---------------------------------------------------------------------------
# Step 3: Build provisioner + reaper
# ---------------------------------------------------------------------------
echo ""
echo "==[3/6]== Building provisioner + reaper (arm64) ..."
make build-provisioner
echo "    provisioner built."

# ---------------------------------------------------------------------------
# Step 4: Build microVM images (all variants, both regions)
# ---------------------------------------------------------------------------
echo ""
echo "==[4/6]== Building microVM images ..."
echo "    (This takes 5-15 min per image; 6 images total = up to 90 min,"
echo "     though AWS often runs them in parallel per region)"
echo ""
make build-images

# ---------------------------------------------------------------------------
# Step 5: Update Lambda env vars with real image ARNs
# ---------------------------------------------------------------------------
echo ""
echo "==[5/6]== Updating provisioner Lambda env vars with image ARNs ..."

for region in "${REGIONS[@]}"; do
  FUNCTION_NAME="microvm-bench-provisioner"

  # Fetch current env (so we don't clobber other vars)
  CURRENT_ENV=$(aws --profile "${AWS_PROFILE}" --region "${region}" \
    lambda get-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --query 'Environment.Variables' --output json 2>/dev/null || echo '{}')

  # Build updated env merging image ARNs
  NEW_ENV=$(echo "${CURRENT_ENV}" | jq --arg r "${region}" --arg a "${ACCOUNT_ID}" '
    . +
    {
      "IMAGE_ARN_BASE": "arn:aws:lambda:\($r):\($a):microvm-image:microvm-bench-base",
      "IMAGE_ARN_MPL":  "arn:aws:lambda:\($r):\($a):microvm-image:microvm-bench-mpl",
      "IMAGE_ARN_SCI":  "arn:aws:lambda:\($r):\($a):microvm-image:microvm-bench-sci"
    }
  ')

  echo "    updating ${FUNCTION_NAME} in ${region} ..."
  aws --profile "${AWS_PROFILE}" --region "${region}" \
    lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --environment "Variables=${NEW_ENV}" \
    --output json > /dev/null

  echo "    updated ${region}."
done

# ---------------------------------------------------------------------------
# Step 6: Deploy frontend
# ---------------------------------------------------------------------------
echo ""
echo "==[6/6]== Deploying frontend ..."
bash scripts/deploy-frontend.sh

echo ""
echo "========================================================"
echo "  Bootstrap complete!"
echo "========================================================"
echo ""
echo "Next steps:"
echo "  make test      — run the benchmark harness (N=3 by default)"
echo "  make estimate  — offline cost estimate"
echo "  make reap      — terminate all bench microVMs"
echo ""
echo "Frontend URL (CloudFront) is printed above by the deploy step."
