#!/usr/bin/env bash
# scripts/build-image.sh — build one microVM image variant in one region.
#
# Usage:
#   VARIANT=base  REGION=us-east-1  bash scripts/build-image.sh
#   VARIANT=mpl   REGION=us-west-2  bash scripts/build-image.sh
#   VARIANT=sci   REGION=us-east-1  bash scripts/build-image.sh
#
# Required env:
#   VARIANT   — base | mpl | sci
#   REGION    — us-east-1 | us-west-2
#
# Optional env:
#   AWS_PROFILE  — defaults to microvm-bench
#   BUILD_ROLE_ARN — defaults to arn:aws:iam::<account-id>:role/microvm-bench-build-role
#   EGRESS_CONNECTOR_ARN — defaults to per-region internet egress ARN
#   POLL_INTERVAL_S — seconds between build status polls (default 30)
#   DRY_RUN   — if set to "1", print the CLI call but don't execute it

set -euo pipefail

# ---------------------------------------------------------------------------
# Config / defaults
# ---------------------------------------------------------------------------
VARIANT="${VARIANT:?VARIANT must be set (base|mpl|sci)}"
REGION="${REGION:?REGION must be set (us-east-1|us-west-2)}"
AWS_PROFILE="${AWS_PROFILE:-microvm-bench}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws --profile "${AWS_PROFILE}" sts get-caller-identity --query Account --output text)}"
BUILD_ROLE_ARN="${BUILD_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/microvm-bench-build-role}"
EGRESS_CONNECTOR_ARN="${EGRESS_CONNECTOR_ARN:-arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-30}"
DRY_RUN="${DRY_RUN:-0}"

# Validate variant
case "${VARIANT}" in
  base|mpl|sci) ;;
  *) echo "ERROR: VARIANT must be base, mpl, or sci (got: ${VARIANT})" >&2; exit 1 ;;
esac

# Memory per variant
case "${VARIANT}" in
  base) MIN_MEM_MIB=512 ;;
  mpl)  MIN_MEM_MIB=1024 ;;
  sci)  MIN_MEM_MIB=1024 ;;
esac

IMAGE_NAME="microvm-bench-${VARIANT}"
IMAGE_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:microvm-image:${IMAGE_NAME}"
BASE_IMAGE_ARN="arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1"
ARTIFACT_BUCKET="microvm-bench-artifacts-${REGION}-${ACCOUNT_ID}"
S3_KEY="build-contexts/${IMAGE_NAME}-$(date +%Y%m%d%H%M%S).zip"
S3_URI="s3://${ARTIFACT_BUCKET}/${S3_KEY}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MICROVM_DIR="${REPO_ROOT}/microvm"

AWS="aws --profile ${AWS_PROFILE} --region ${REGION}"

# ---------------------------------------------------------------------------
# emit_image_metadata <version> — surface the image + snapshot facts AWS exposes
# (and which we otherwise never see locally): architecture (ARM_64/Graviton),
# minimum memory, version, imageArn/imageId, base image, build role, code artifact,
# build log group, and the snapshot byte-sizes (memory/code/disk) read from the
# build record. Prints a block, writes results/image-metadata-<region>-<variant>.json,
# and uploads a durable copy to S3 so the record is cloud-visible, not just local.
# NOTE: realized vCPU is not in the image API — it is set at RunMicrovm time (the
# provisioner logs it as 'microvm_descriptor').
# ---------------------------------------------------------------------------
emit_image_metadata() {
  local ver="$1"
  local img_json ver_json manifest build_id build_json
  img_json=$(${AWS} lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" 2>/dev/null || echo '{}')
  ver_json=$(${AWS} lambda-microvms get-microvm-image-version --image-identifier "${IMAGE_ARN}" --image-version "${ver}" 2>/dev/null || echo '{}')
  # The actual snapshot byte-sizes live on the BUILD record, not the version.
  build_id=$(${AWS} lambda-microvms list-microvm-image-builds --image-identifier "${IMAGE_ARN}" --image-version "${ver}" --query 'items[0].buildId' --output text 2>/dev/null || echo "")
  build_json='{}'
  if [ -n "${build_id}" ] && [ "${build_id}" != "None" ]; then
    build_json=$(${AWS} lambda-microvms get-microvm-image-build --image-identifier "${IMAGE_ARN}" --image-version "${ver}" --build-id "${build_id}" 2>/dev/null || echo '{}')
  fi

  manifest=$(jq -n \
    --arg region "${REGION}" \
    --arg variant "${VARIANT}" \
    --argjson img "${img_json}" \
    --argjson ver "${ver_json}" \
    --argjson build "${build_json}" '
    {
      region:                   $region,
      variant:                  $variant,
      imageName:                ($img.name // null),
      imageArn:                 ($ver.imageArn // $img.imageArn),
      version:                  $ver.imageVersion,
      imageState:               $img.state,
      versionState:             $ver.state,
      versionStatus:            $ver.status,
      latestActiveImageVersion: $img.latestActiveImageVersion,
      architecture:             ($ver.cpuConfigurations[0].architecture // null),
      minimumMemoryInMiB:       ($ver.resources[0].minimumMemoryInMiB // null),
      baseImageArn:             $ver.baseImageArn,
      baseImageVersion:         $ver.baseImageVersion,
      buildRoleArn:             $ver.buildRoleArn,
      codeArtifact:             ($ver.codeArtifact.uri // null),
      buildLogGroup:            ($ver.logging.cloudWatch.logGroup // null),
      egressNetworkConnectors:  ($ver.egressNetworkConnectors // []),
      hooksPort:                ($ver.hooks.port // null),
      buildId:                  ($build.buildId // null),
      memorySnapshotBytes:      ($build.snapshotBuild.memorySnapshotSizeInBytes // null),
      codeInstallBytes:         ($build.snapshotBuild.codeInstallSizeInBytes // null),
      diskSnapshotBytes:        ($build.snapshotBuild.diskSnapshotSizeInBytes // null),
      createdAt:                $ver.createdAt,
      updatedAt:                $ver.updatedAt,
      tags:                     ($img.tags // {})
    }') || manifest='{}'

  echo ""
  echo "==> IMAGE METADATA (${IMAGE_NAME} @ ${REGION})"
  echo "${manifest}" | jq -r '
    "    imageArn:        \(.imageArn)",
    "    version:         \(.version)  (image=\(.imageState) version=\(.versionState)/\(.versionStatus))",
    "    architecture:    \(.architecture)   minMemory: \(.minimumMemoryInMiB) MiB",
    "    baseImage:       \(.baseImageArn) @ \(.baseImageVersion)",
    "    buildRole:       \(.buildRoleArn)",
    "    codeArtifact:    \(.codeArtifact)",
    "    buildLogGroup:   \(.buildLogGroup)",
    "    hooks.port:      \(.hooksPort)",
    "    snapshot(MiB):   mem=\(((.memorySnapshotBytes // 0)/1048576)|floor) code=\(((.codeInstallBytes // 0)/1048576)|floor) disk=\(((.diskSnapshotBytes // 0)/1048576)|floor)  (buildId \(.buildId))",
    "    created/updated: \(.createdAt) / \(.updatedAt)"' 2>/dev/null || true
  echo "    (realized vCPU is set at RunMicrovm time; see the provisioner"
  echo "     'microvm_descriptor' CloudWatch log for run-time facts)"

  local outdir="${REPO_ROOT}/results"
  mkdir -p "${outdir}"
  echo "${manifest}" | jq . > "${outdir}/image-metadata-${REGION}-${VARIANT}.json" 2>/dev/null || true
  echo "    wrote ${outdir}/image-metadata-${REGION}-${VARIANT}.json"

  local s3key="image-metadata/${IMAGE_NAME}-${ver}.json"
  if echo "${manifest}" | ${AWS} s3 cp - "s3://${ARTIFACT_BUCKET}/${s3key}" --content-type application/json >/dev/null 2>&1; then
    echo "    uploaded s3://${ARTIFACT_BUCKET}/${s3key}"
  else
    echo "    (s3 upload of metadata skipped/failed — non-fatal)"
  fi
}

echo "==> Building image: ${IMAGE_NAME} in ${REGION}"
echo "    variant=${VARIANT}  memory=${MIN_MEM_MIB} MiB  base=${BASE_IMAGE_ARN}"
echo "    artifact: ${S3_URI}"
echo ""

# ---------------------------------------------------------------------------
# 1. Zip the build context
# ---------------------------------------------------------------------------
# Context layout:
#   Dockerfile        (renamed from Dockerfile.<variant>)
#   manager/          (Rust manager source)
#   forkserver/       (Python fork-server)
#   samples/          (smoke-test sample scripts)
# ---------------------------------------------------------------------------
BUILD_CTX_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_CTX_DIR}"' EXIT

echo "==> Assembling build context in ${BUILD_CTX_DIR} ..."

# Copy the variant Dockerfile as "Dockerfile" (AWS needs it at root)
cp "${MICROVM_DIR}/images/Dockerfile.${VARIANT}" "${BUILD_CTX_DIR}/Dockerfile"

# Copy microvm sub-trees that the Dockerfile references
cp -r "${MICROVM_DIR}/manager"    "${BUILD_CTX_DIR}/manager"
cp -r "${MICROVM_DIR}/forkserver" "${BUILD_CTX_DIR}/forkserver"
cp -r "${MICROVM_DIR}/samples"    "${BUILD_CTX_DIR}/samples"
# The Dockerfile does `COPY images/shrink.sh ...`, so the context MUST contain
# images/shrink.sh. (Local buildx used ./microvm as context, which already has it;
# the assembled server-side context did not — this was the real CREATE_FAILED.)
mkdir -p "${BUILD_CTX_DIR}/images"
cp "${MICROVM_DIR}/images/shrink.sh" "${BUILD_CTX_DIR}/images/shrink.sh"

# Prune build cruft so the uploaded context stays small: the Dockerfile rebuilds
# the Rust manager from Cargo.* + src, so the local cargo target/ (hundreds of MB)
# must NOT ship; likewise Python bytecode caches. Without this the context was
# ~238 MB (target/ alone is ~600 MB raw) — slow to upload AND download server-side.
rm -rf "${BUILD_CTX_DIR}/manager/target"
find "${BUILD_CTX_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_CTX_DIR}" -type f -name '*.pyc' -delete 2>/dev/null || true

# Zip (no top-level directory wrapper — AWS expects flat Dockerfile at root).
# Use python3's zipfile (always present in our toolchain) so `zip` is not a hard
# prereq; -c recurses into the listed directories.
ZIP_PATH="${BUILD_CTX_DIR}/context.zip"
(cd "${BUILD_CTX_DIR}" && python3 -m zipfile -c "${ZIP_PATH}" Dockerfile manager forkserver samples images)

echo "    context size: $(du -sh "${ZIP_PATH}" | cut -f1)"

# ---------------------------------------------------------------------------
# 2. Upload to S3
# ---------------------------------------------------------------------------
echo "==> Uploading build context to ${S3_URI} ..."
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "    [DRY_RUN] would run: ${AWS} s3 cp ${ZIP_PATH} ${S3_URI}"
else
  ${AWS} s3 cp "${ZIP_PATH}" "${S3_URI}"
  echo "    upload complete."
fi

# ---------------------------------------------------------------------------
# 3. Create or update the microVM image
# ---------------------------------------------------------------------------
# Build the hooks JSON (all 6 hooks enabled; hooks.port = 9000 — see below)
# hooks.port MUST be 9000, NOT 8080: 8080 is AWS's data-plane endpoint default,
# and AWS's build-time hook POST never reaches an app whose hooks.port is 8080
# (proven via the instrumented build trail). The AWS reference sample uses 9000.
# The manager listens on BOTH 8080 (data-plane /exec) and 9000 (hooks).
HOOKS_JSON=$(cat <<EOF
{
  "port": 9000,
  "microvmHooks": {
    "run":                   "ENABLED", "runTimeoutInSeconds":       30,
    "resume":                "ENABLED", "resumeTimeoutInSeconds":    30,
    "suspend":               "ENABLED", "suspendTimeoutInSeconds":   30,
    "terminate":             "ENABLED", "terminateTimeoutInSeconds": 30
  },
  "microvmImageHooks": {
    "ready":                 "ENABLED", "readyTimeoutInSeconds":    300,
    "validate":              "ENABLED", "validateTimeoutInSeconds": 300
  }
}
EOF
)

RESOURCES_JSON="[{\"minimumMemoryInMiB\": ${MIN_MEM_MIB}}]"
CPU_JSON='[{"architecture": "ARM_64"}]'
TAGS_JSON='{"Project": "microvm-bench"}'
# IMPORTANT (root cause of the "Ready hook invocation timed out" failures):
# do NOT attach a build-time egress network connector. The AWS reference sample
# (aws-samples/sample-lambda-microvm-claude-managed-agents) attaches NO connectors
# at all, yet its Docker build still has internet (dnf/npm install) — AWS's build
# infra provides Docker-build connectivity automatically. Attaching
# --egress-network-connectors reconfigures the build microVM's networking and
# (confirmed empirically: instrumented manager never received AWS's /ready POST)
# BREAKS delivery of the build-time /ready hook to the app on :8080. Opt in ONLY
# if a variant genuinely needs app-level egress DURING the build, by exporting
# BUILD_EGRESS_CONNECTOR_ARN — but the Docker build itself does not need it.
EGRESS_ARG=()
if [[ -n "${BUILD_EGRESS_CONNECTOR_ARN:-}" ]]; then
  EGRESS_ARG=(--egress-network-connectors "[\"${BUILD_EGRESS_CONNECTOR_ARN}\"]")
fi
# Enable CloudWatch build logging — WITHOUT this, build logs default off and a
# CREATE_FAILED gives no reason (the build role must be able to write here; infra
# grants logs on arn:aws:logs:*:*:*).
BUILD_LOG_GROUP="/microvm-bench/imagebuild/${IMAGE_NAME}"
LOGGING_JSON="{\"cloudWatch\":{\"logGroup\":\"${BUILD_LOG_GROUP}\"}}"

echo "==> Checking if image ${IMAGE_NAME} already exists in ${REGION} ..."
EXISTING_STATE=""
OLD_ACTIVE_VERSION=""
if [[ "${DRY_RUN}" != "1" ]]; then
  # Real CLI flag is --image-identifier (accepts the image name or ARN), NOT
  # --image-name. Verified via `aws lambda-microvms get-microvm-image help`.
  IMG0=$(${AWS} lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" 2>/dev/null || true)
  if [[ -n "${IMG0}" ]]; then
    EXISTING_STATE=$(echo "${IMG0}" | jq -r '.state // empty')
    # Capture the currently-active version so the UPDATE poll can detect when a
    # NEW version supersedes it (an update leaves image .state at CREATED while a
    # new VERSION builds — polling .state alone would falsely report success).
    OLD_ACTIVE_VERSION=$(echo "${IMG0}" | jq -r '.latestActiveImageVersion // empty')
  fi
  echo "    existing state: ${EXISTING_STATE:-<none>}  active version: ${OLD_ACTIVE_VERSION:-<none>}"
fi

# Self-heal failed/transient states: a CREATE_FAILED/DELETE_FAILED image cannot be
# updated — delete it; a DELETING image must finish before we recreate.
case "${EXISTING_STATE}" in
  CREATE_FAILED|DELETE_FAILED|ROLLBACK_FAILED)
    echo "    image is ${EXISTING_STATE}; deleting before recreate ..."
    ${AWS} lambda-microvms delete-microvm-image --image-identifier "${IMAGE_ARN}" >/dev/null 2>&1 || true
    EXISTING_STATE="DELETING"
    ;;
esac
if [[ "${EXISTING_STATE}" == "DELETING" ]]; then
  echo "    waiting for delete to finish ..."
  for _ in $(seq 1 30); do
    s=$(${AWS} lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" --query state --output text 2>/dev/null || true)
    { [[ -z "${s}" || "${s}" == "None" ]]; } && { EXISTING_STATE=""; break; }
    sleep 5
  done
fi

CREATE_OR_UPDATE=""
if [[ "${DRY_RUN}" == "1" ]]; then
  CREATE_OR_UPDATE="create"
elif [[ -z "${EXISTING_STATE:-}" ]]; then
  CREATE_OR_UPDATE="create"
else
  CREATE_OR_UPDATE="update"
fi

if [[ "${CREATE_OR_UPDATE}" == "create" ]]; then
  echo "==> Creating microvm image: ${IMAGE_NAME} ..."
  CREATE_CMD=(
    ${AWS} lambda-microvms create-microvm-image
    --name "${IMAGE_NAME}"
    --base-image-arn "${BASE_IMAGE_ARN}"
    --build-role-arn "${BUILD_ROLE_ARN}"
    --code-artifact "{\"uri\": \"${S3_URI}\"}"
    --cpu-configurations "${CPU_JSON}"
    --resources "${RESOURCES_JSON}"
    "${EGRESS_ARG[@]}"
    --hooks "${HOOKS_JSON}"
    --logging "${LOGGING_JSON}"
    --tags "${TAGS_JSON}"
  )
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "    [DRY_RUN] would run: ${CREATE_CMD[*]}"
    echo "==> Done (dry run)."
    exit 0
  fi
  CREATE_OUT=$("${CREATE_CMD[@]}")
  echo "    image creation started:"
  echo "${CREATE_OUT}" | jq -r '"      state=\(.state // "?")  version=\(.imageVersion // .latestActiveImageVersion // "?")"' 2>/dev/null || true
else
  echo "==> Updating microvm image: ${IMAGE_NAME} ..."
  # update-microvm-image takes --image-identifier (NOT --image-name; verified via
  # `aws lambda-microvms update-microvm-image help`). --base-image-arn and
  # --build-role-arn are REQUIRED on every build-triggering update, even for a
  # code-only change (see the aws-lambda-microvms skill) — both are passed below.
  # NOTE: update-microvm-image does NOT accept --tags (create does; the update
  # synopsis has no --tags — passing it fails "Unknown options: --tags"). Tags
  # set at create time persist across updates, so they are simply not re-sent.
  UPDATE_CMD=(
    ${AWS} lambda-microvms update-microvm-image
    --image-identifier "${IMAGE_ARN}"
    --base-image-arn "${BASE_IMAGE_ARN}"
    --build-role-arn "${BUILD_ROLE_ARN}"
    --code-artifact "{\"uri\": \"${S3_URI}\"}"
    --cpu-configurations "${CPU_JSON}"
    --resources "${RESOURCES_JSON}"
    "${EGRESS_ARG[@]}"
    --hooks "${HOOKS_JSON}"
    --logging "${LOGGING_JSON}"
  )
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "    [DRY_RUN] would run: ${UPDATE_CMD[*]}"
    echo "==> Done (dry run)."
    exit 0
  fi
  UPDATE_OUT=$("${UPDATE_CMD[@]}")
  echo "    image update started:"
  echo "${UPDATE_OUT}" | jq -r '"      state=\(.state // "?")  version=\(.imageVersion // .latestActiveImageVersion // "?")"' 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Poll the VERSION build status (NOT the image .state).
#
# A microVM image has two state machines that move independently:
#   - image .state: CREATING -> CREATED (and STAYS CREATED across updates).
#   - version .state: PENDING -> IN_PROGRESS -> SUCCESSFUL | FAILED  (the build),
#     and version .status: ACTIVE | INACTIVE                          (activation).
# A microVM runs only when image ∈ {CREATED,UPDATED} AND a version is SUCCESSFUL
# AND ACTIVE. So on an UPDATE the image is ALREADY CREATED while the NEW version
# builds — polling image .state would falsely declare success immediately. We
# therefore poll the newest version's .state, and consider the build done only
# when a version NEWER than the previously-active one is SUCCESSFUL+ACTIVE
# (latestActiveImageVersion advanced). Create auto-activates the first version;
# if an update's new version lands SUCCESSFUL but INACTIVE we activate it
# explicitly (update-microvm-image-version --status ACTIVE).
# ---------------------------------------------------------------------------
echo ""
echo "==> Polling build status for ${IMAGE_ARN} every ${POLL_INTERVAL_S}s ..."
echo "    (the server-side Graviton build typically takes 5-15 minutes)"
echo "    previously-active version: ${OLD_ACTIVE_VERSION:-<none>}"
ATTEMPTS=0
MAX_ATTEMPTS=60 # 60 × 30 s = 30 min hard ceiling

# Highest imageVersion across all versions (numeric major.minor sort).
newest_version() {
  ${AWS} lambda-microvms list-microvm-image-versions --image-identifier "${IMAGE_ARN}" 2>/dev/null \
    | jq -r '(.items // [])[].imageVersion' 2>/dev/null \
    | sort -t. -k1,1n -k2,2n | tail -1
}

while true; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [[ ${ATTEMPTS} -gt ${MAX_ATTEMPTS} ]]; then
    echo "ERROR: Build did not complete within $((MAX_ATTEMPTS * POLL_INTERVAL_S / 60)) minutes." >&2
    exit 1
  fi

  VER=$(newest_version)
  if [[ -z "${VER}" || "${VER}" == "null" ]]; then
    printf "    [%3d] no version yet ...\n" "${ATTEMPTS}"
    sleep "${POLL_INTERVAL_S}"
    continue
  fi

  if ! VJSON=$(${AWS} lambda-microvms get-microvm-image-version \
      --image-identifier "${IMAGE_ARN}" --image-version "${VER}" 2>&1); then
    echo "    [${ATTEMPTS}] get-microvm-image-version error (retrying): ${VJSON}" >&2
    sleep "${POLL_INTERVAL_S}"
    continue
  fi
  VSTATE=$(echo "${VJSON}" | jq -r '.state // "UNKNOWN"')   # build:      SUCCESSFUL|FAILED|...
  VSTATUS=$(echo "${VJSON}" | jq -r '.status // "UNKNOWN"') # activation: ACTIVE|INACTIVE
  REASON=$(echo "${VJSON}" | jq -r '.stateReason // .statusReason // ""')

  printf "    [%3d] version=%-5s state=%-12s status=%-9s %s\n" \
    "${ATTEMPTS}" "${VER}" "${VSTATE}" "${VSTATUS}" "${REASON}"

  # On UPDATE, the newest version is still the OLD active one until the new build
  # registers — keep waiting until a strictly newer version appears.
  if [[ -n "${OLD_ACTIVE_VERSION}" && "${VER}" == "${OLD_ACTIVE_VERSION}" ]]; then
    sleep "${POLL_INTERVAL_S}"
    continue
  fi

  case "${VSTATE}" in
    SUCCESSFUL)
      if [[ "${VSTATUS}" != "ACTIVE" ]]; then
        echo "    version ${VER} built SUCCESSFUL but INACTIVE; activating ..."
        ${AWS} lambda-microvms update-microvm-image-version \
          --image-identifier "${IMAGE_ARN}" --image-version "${VER}" --status ACTIVE >/dev/null 2>&1 || true
        sleep 3
      fi
      LAV=$(${AWS} lambda-microvms get-microvm-image --image-identifier "${IMAGE_ARN}" \
        --query latestActiveImageVersion --output text 2>/dev/null || true)
      echo ""
      echo "==> Build SUCCESSFUL.  version=${VER}  latestActiveImageVersion=${LAV}"
      echo "Image ARN: ${IMAGE_ARN}"
      echo ""
      echo "RunMicrovm uses the latest ACTIVE version by default, so the provisioner"
      echo "picks up ${VER} automatically (IMAGE_ARN_${VARIANT^^} is unchanged)."

      # Surface + persist the image facts AWS exposes (arch/memory/version/...).
      emit_image_metadata "${VER}" || echo "    (metadata surfacing failed — non-fatal)"
      exit 0
      ;;
    FAILED | CREATE_FAILED | ROLLBACK_FAILED)
      echo ""
      echo "ERROR: Build FAILED (version ${VER}). Reason: ${REASON}" >&2
      echo "Check CloudWatch Logs (/microvm-bench/imagebuild/${IMAGE_NAME})." >&2
      exit 1
      ;;
  esac

  sleep "${POLL_INTERVAL_S}"
done
