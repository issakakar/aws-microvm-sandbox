#!/usr/bin/env bash
# scripts/reap.sh — list all bench microVMs (by image ARN) and terminate them.
#
# Usage:
#   bash scripts/reap.sh                 # both regions, prompt before terminate
#   REGION=us-east-1 bash scripts/reap.sh   # single region
#   YES=1 bash scripts/reap.sh           # skip confirmation prompt
#
# This is the manual counterpart to the EventBridge reaper Lambda (which runs
# every 5 min and only kills VMs older than TTL). This script terminates ALL
# bench microVMs regardless of age, identifying them by the bench image ARN
# (RunMicrovm has no per-VM Tags field — see the body below and the reaper).

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-microvm-bench}"
YES="${YES:-0}"

# Regions to sweep — override with REGION env var
if [[ -n "${REGION:-}" ]]; then
  REGIONS=("${REGION}")
else
  REGIONS=("us-east-1" "us-west-2")
fi

AWS_BASE="aws --profile ${AWS_PROFILE}"

total_found=0
total_terminated=0

for region in "${REGIONS[@]}"; do
  AWS="${AWS_BASE} --region ${region}"

  echo "==> Listing microvm-bench microVMs in ${region} ..."

  # List all microVMs; identify OURS by the bench image-ARN marker (RunMicrovm
  # has no Tags field in the GA API, so tag-based filtering finds nothing — this
  # mirrors the reaper Lambda's isOurs() check). Field names are tolerant to CLI
  # casing (items/microvms, microvmId/MicrovmId, imageArn/ImageArn, state/State).
  MVM_IDS=$(${AWS} lambda-microvms list-microvms \
      --output json 2>/dev/null \
    | jq -r '
        (.items // .microvms // [])[]
        | select(((.imageArn // .ImageArn) // "") | contains("microvm-image:microvm-bench-"))
        | select(((.state // .State) // "") != "TERMINATED" and ((.state // .State) // "") != "TERMINATING")
        | (.microvmId // .MicrovmId)
      ' 2>/dev/null || true)

  if [[ -z "${MVM_IDS}" ]]; then
    echo "    none found in ${region}."
    continue
  fi

  COUNT=$(echo "${MVM_IDS}" | wc -l | tr -d ' ')
  total_found=$((total_found + COUNT))
  echo "    found ${COUNT} microVM(s) in ${region}:"
  echo "${MVM_IDS}" | sed 's/^/      /'

  if [[ "${YES}" != "1" ]]; then
    printf "\n    Terminate all %d microVM(s) in %s? [y/N] " "${COUNT}" "${region}"
    read -r answer </dev/tty
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
      echo "    skipping ${region}."
      continue
    fi
  fi

  echo "    terminating ..."
  while IFS= read -r mvm_id; do
    [[ -z "${mvm_id}" ]] && continue
    echo -n "      terminate ${mvm_id} ... "
    if ${AWS} lambda-microvms terminate-microvm \
        --microvm-identifier "${mvm_id}" \
        --output json > /dev/null 2>&1; then
      echo "OK"
      total_terminated=$((total_terminated + 1))
    else
      echo "FAILED (may already be terminating)"
    fi
  done <<< "${MVM_IDS}"
done

echo ""
echo "==> Reap complete: found ${total_found}, terminated ${total_terminated}."
