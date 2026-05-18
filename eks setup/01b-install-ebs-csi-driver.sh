#!/usr/bin/env bash
# Installs the AWS EBS CSI Driver on the EKS cluster so that
# PersistentVolumeClaims (e.g. MySQL data volume) can be provisioned.
# Must run AFTER 01-create-cluster.sh and BEFORE 02-install-argocd.sh.
#
# Usage: ./01b-install-ebs-csi-driver.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-lumiatechs-eks-cluster}"
REGION="${2:-us-east-1}"

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "==> [1/4] Associating IAM OIDC provider with cluster '${CLUSTER_NAME}' ..."
eksctl utils associate-iam-oidc-provider \
  --region  "${REGION}" \
  --cluster "${CLUSTER_NAME}" \
  --approve

echo ""
echo "==> [2/4] Creating IAM service account for EBS CSI controller ..."
# --role-only creates the IAM role without a Kubernetes service account;
# the addon step below links the role via annotation.
eksctl create iamserviceaccount \
  --name      ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster   "${CLUSTER_NAME}" \
  --region    "${REGION}" \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole

echo ""
echo "==> [3/4] Installing aws-ebs-csi-driver EKS add-on ..."
eksctl create addon \
  --name    aws-ebs-csi-driver \
  --cluster "${CLUSTER_NAME}" \
  --region  "${REGION}" \
  --service-account-role-arn \
    "arn:aws:iam::${AWS_ACCOUNT}:role/AmazonEKS_EBS_CSI_DriverRole" \
  --force

echo ""
echo "==> [4/4] Waiting for EBS CSI driver pods to be Ready ..."
# Roll through each EBS CSI deployment/daemonset rather than --all
# to avoid failures on completed init pods.
for deploy in ebs-csi-controller; do
  if kubectl get deploy "${deploy}" -n kube-system &>/dev/null; then
    kubectl rollout status deploy/"${deploy}" -n kube-system --timeout=120s
  fi
done
for ds in ebs-csi-node; do
  if kubectl get daemonset "${ds}" -n kube-system &>/dev/null; then
    kubectl rollout status daemonset/"${ds}" -n kube-system --timeout=120s
  fi
done

echo ""
echo "==> EBS CSI Driver installed. Storage classes available:"
kubectl get storageclass
