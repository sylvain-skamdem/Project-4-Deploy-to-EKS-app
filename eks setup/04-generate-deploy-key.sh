#!/usr/bin/env bash
# Generates the SSH deploy key pair used by GitHub Actions to push tag updates
# to the manifest repo.  Run this once on your local machine.
#
# After running:
#   1. Add manifest_deploy_key.pub as a deploy key (with write access) in
#      https://github.com/<you>/Project-4-Deploy-to-EKS-manifest → Settings → Deploy keys
#   2. Add the private key contents as the MANIFEST_REPO_SSH_KEY secret in
#      the app repo → Settings → Secrets and variables → Actions
#   3. Delete both key files from your machine.
set -euo pipefail

KEY_FILE="manifest_deploy_key"

if [[ -f "${KEY_FILE}" ]]; then
  echo "Key file '${KEY_FILE}' already exists. Remove it first if you want to regenerate."
  exit 1
fi

echo "==> Generating ed25519 deploy key ..."
ssh-keygen -t ed25519 -C "github-actions-lumiatech" -f "${KEY_FILE}" -N ""

echo ""
echo "==> Public key (add this to the manifest repo as a deploy key):"
echo "---"
cat "${KEY_FILE}.pub"
echo "---"

echo ""
echo "==> Private key (add the full contents as MANIFEST_REPO_SSH_KEY in the app repo secrets):"
echo "---"
cat "${KEY_FILE}"
echo "---"

echo ""
echo "IMPORTANT: Delete both files once you have saved the keys:"
echo "  rm ${KEY_FILE} ${KEY_FILE}.pub"
