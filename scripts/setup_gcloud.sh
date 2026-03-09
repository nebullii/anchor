#!/usr/bin/env bash
set -euo pipefail

echo "Checking gcloud installation..."
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found. Install it first:"
  echo "  Mac: brew install google-cloud-sdk"
  echo "  Other OS: https://cloud.google.com/sdk/docs/install"
  exit 1
fi

echo "Checking authentication..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format=value(account) || true)
if [ -z "${ACTIVE_ACCOUNT}" ]; then
  echo "No active account found. Starting login..."
  gcloud auth login
else
  echo "Authenticated as: ${ACTIVE_ACCOUNT}"
fi

echo "Listing projects..."
gcloud projects list --format=table(projectId,name)

echo ""
echo "If you need a new project, create it in the Cloud Console:"
echo "https://console.cloud.google.com/projectcreate"
echo ""
echo "If billing is not linked, open Billing and link it to your project:"
echo "https://console.cloud.google.com/billing"
