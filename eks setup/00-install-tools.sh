#!/usr/bin/env bash
# Installs AWS CLI, eksctl, kubectl, and Helm 3 on a Linux x86_64 machine.
# Run this once before any other script.
set -euo pipefail

echo "==> [1/4] Installing AWS CLI v2"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws
aws --version

echo "==> [2/4] Installing eksctl"
curl --silent --location \
  "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" \
  | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin/eksctl
eksctl version

echo "==> [3/4] Installing kubectl"
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client

echo "==> [4/4] Installing Helm 3"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

echo "==> [5/5] Installing ArgoCD CLI"
ARGOCD_VERSION=$(curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
curl -fsSL -o /tmp/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
rm /tmp/argocd
argocd version --client

echo ""
echo "All tools installed. Run 'aws configure' to set your credentials before proceeding."
