#!/usr/bin/env bash
# scripts/deploy-frontend.sh — build the SPA and deploy it to AWS.
#
#   pnpm build  ->  aws s3 sync dist/ -> s3://<spa bucket>  ->  CloudFront invalidate
#
# The browser path is 100% AWS: CloudFront (SPA on S3 + OAC-signed /api/use1/* and
# /api/usw2/* behaviors → the regional provisioner Function URLs). Region is chosen
# by path; the SPA's region selector picks it.
#
# Requires:
#   - terraform applied in infra/ (outputs spa_bucket + cloudfront_distribution_id)
#   - pnpm + aws CLI (profile microvm-bench)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${REPO_ROOT}/infra"
FRONTEND_DIR="${REPO_ROOT}/frontend"
AWS_PROFILE="${AWS_PROFILE:-microvm-bench}"
export AWS_PROFILE

echo "==> Reading Terraform outputs from ${INFRA_DIR} ..."
TF_OUT=$(cd "${INFRA_DIR}" && terraform output -json)
BUCKET=$(echo "${TF_OUT}"  | jq -r '.spa_bucket.value // empty')
DIST_ID=$(echo "${TF_OUT}" | jq -r '.cloudfront_distribution_id.value // empty')
APP_URL=$(echo "${TF_OUT}" | jq -r '.app_url.value // empty')

if [[ -z "${BUCKET}" || -z "${DIST_ID}" ]]; then
  echo "ERROR: missing spa_bucket / cloudfront_distribution_id outputs. Run 'make deploy-infra' first." >&2
  exit 1
fi
echo "    bucket=${BUCKET}  distribution=${DIST_ID}"

# ---------------------------------------------------------------------------
# Build the SPA (plain Vite → frontend/dist)
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing + building SPA (pnpm) ..."
(cd "${FRONTEND_DIR}" && pnpm install && pnpm build)
echo "    build complete."

# ---------------------------------------------------------------------------
# Sync to S3. Hashed assets get a long immutable cache; index.html is never
# cached so a new deploy is visible immediately (CloudFront still invalidated).
# ---------------------------------------------------------------------------
echo ""
echo "==> Syncing dist/ -> s3://${BUCKET}/ ..."
aws s3 sync "${FRONTEND_DIR}/dist/" "s3://${BUCKET}/" --delete --region us-east-1 \
  --exclude index.html --cache-control "public,max-age=31536000,immutable"
aws s3 cp "${FRONTEND_DIR}/dist/index.html" "s3://${BUCKET}/index.html" --region us-east-1 \
  --cache-control "no-cache" --content-type "text/html"

# ---------------------------------------------------------------------------
# Invalidate CloudFront so the new build is served right away.
# ---------------------------------------------------------------------------
echo ""
echo "==> Invalidating CloudFront (${DIST_ID}) ..."
aws cloudfront create-invalidation --distribution-id "${DIST_ID}" --paths '/*' \
  --query 'Invalidation.{Id:Id,Status:Status}' --output table

echo ""
echo "==> Frontend deployed. Open in a browser (tests BOTH regions; selector in the UI):"
echo "    ${APP_URL}"
