# Project 4 — Lumiatech App Repository

This repository contains the **Java Spring MVC application source code, Dockerfiles, and GitHub Actions CI/CD pipeline**. On every push to `main`, the pipeline builds the app, pushes Docker images to Docker Hub, and updates the image tags in the Helm manifest repository so the EKS cluster picks up the new version automatically via ArgoCD.

Kubernetes manifests and EKS cluster provisioning are maintained in the companion repository:  
**[Project-4-Deploy-to-EKS-manifest](https://github.com/Ndzenyuy/Project-4-Deploy-to-EKS-manifest)**

![Architecture](images/project-4-deploy-to-eks.png)

---

## How the Pipeline Works

```
[Push to main]
      │
      ▼
[GitHub Actions — Job 1: build-and-push]
  ├── Build WAR with Maven (JDK 17)
  ├── Build Docker image → ndzenyuy/lumia-app:<sha>
  └── Build Docker image → ndzenyuy/lumia-db:<sha>
      │
      ▼
[GitHub Actions — Job 2: update-manifests]
  └── Clone manifest repo → patch values.yaml with new SHA → push
      │
      ▼
[ArgoCD on EKS detects change → rolls out new pods]
```

---

## Application Stack

| Service   | Technology         | Purpose               |
|-----------|--------------------|-----------------------|
| App       | Tomcat 10 / JDK 21 | Spring MVC WAR        |
| Database  | MySQL 8.0.33       | Accounts data         |
| Cache     | Memcached          | Session/query caching |
| Messaging | RabbitMQ           | Async message queue   |
| Search    | Elasticsearch 7.10 | Full-text search      |
| Web/Proxy | Nginx              | Reverse proxy (local) |

---

## Full Setup Guide

### What You Need Before Starting

- A **GitHub** account
- A **Docker Hub** account — [hub.docker.com](https://hub.docker.com)
- An **AWS account** with permissions to create EKS clusters, IAM roles, VPCs, and ECR (or Docker Hub for images)
- The **AWS CLI** configured locally (`aws configure`)
- **kubectl** installed — [install guide](https://kubernetes.io/docs/tasks/tools/)
- **eksctl** installed — [install guide](https://eksctl.io/installation/)
- **Helm** installed — [install guide](https://helm.sh/docs/intro/install/)
- **ArgoCD CLI** installed — [install guide](https://argo-cd.readthedocs.io/en/stable/cli_installation/)
- **Java JDK 17** — [Adoptium](https://adoptium.net)
- **Apache Maven 3.8+** — [maven.apache.org](https://maven.apache.org)
- **Docker 24+** — [docs.docker.com](https://docs.docker.com/get-docker/)
- **Git**

```bash
# 1. AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws --version

# 2. eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# 3. kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client

# 4. Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# 5. ArgoCD CLI
ARGOCD_VERSION=$(curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)
curl -fsSL -o /tmp/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64"
sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
argocd version --client
```

> All five tools are also installed automatically by running `bash "eks setup/00-install-tools.sh"`.

---

### WSL2 DNS Fix (Windows users only)

If you are running the setup scripts from WSL2 on Windows, the default WSL DNS proxy (`172.23.192.1`) often cannot reach AWS endpoints, causing `i/o timeout` errors on any `eksctl`, `aws`, or `kubectl` command. Fix this once before running any scripts.

**1. Find the DNS server Windows is actually using:**

```bash
powershell.exe -c "Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses"
```

Look for the entry with a non-empty `ServerAddresses` on your active connection (usually `Wi-Fi` or `Ethernet`). For example:

```
InterfaceAlias    ServerAddresses
--------------    ---------------
Wi-Fi             {192.168.1.1}
```

**2. Point WSL at that DNS server with a fallback:**

```bash
# Replace 192.168.1.1 with the IP you found above.
# 1.1.1.1 (Cloudflare) is added as a fallback in case the router DNS is slow
# for long AWS hostnames (e.g. EKS cluster API server endpoints).
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 192.168.1.1
nameserver 1.1.1.1
EOF'
```

> Do not use `8.8.8.8` — UDP port 53 to Google DNS is commonly blocked on home/office routers.

**3. Verify it resolves AWS endpoints:**

```bash
nslookup oidc.eks.us-east-1.amazonaws.com
# Should return one or more IP addresses — not a timeout
```

**4. Make the fix permanent** (prevents WSL from overwriting `resolv.conf` on restart):

```bash
sudo bash -c 'cat > /etc/wsl.conf << EOF
[network]
generateResolvConf = false
EOF'
```

The fix survives reboots. You only need to do this once per WSL installation.

**If a script fails mid-run with a DNS timeout**, the underlying AWS operation (CloudFormation, eksctl) usually continues asynchronously. Check the actual state before retrying:

```bash
# Check for in-progress or failed CloudFormation stacks
aws cloudformation list-stacks --region us-east-1 \
  --stack-status-filter DELETE_IN_PROGRESS DELETE_FAILED CREATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName, `lumiatech`)].{Name:StackName,Status:StackStatus}' \
  --output table

# Check if the EKS cluster still exists
eksctl get cluster --region us-east-1
```

If stacks show `DELETE_IN_PROGRESS`, wait a few minutes — AWS will finish without your client. If they show `DELETE_FAILED`, re-run the relevant script; eksctl and eksctl commands are idempotent.

---

### Step 1 — Fork and Clone Both Repositories

You need both repositories: the app repo (this one) and the manifest repo.

```bash
# Fork both repos on GitHub first, then clone your forks:

git clone https://github.com/<your-username>/Project-4-Deploy-to-EKS-app.git
git clone https://github.com/<your-username>/Project-4-Deploy-to-EKS-manifest.git
```

> If you are not forking, clone the originals but note you will need write access to the manifest repo for the pipeline to push changes.

---

### Step 2 — Update Image Names to Your Docker Hub Account

The pipeline pushes images to Docker Hub under a specific username. Update the image names to use your own Docker Hub username.

In `.github/workflows/build-and-update.yml`, change the `env` block at the top:

```yaml
env:
  APP_IMAGE: <your-dockerhub-username>/lumia-app
  DB_IMAGE:  <your-dockerhub-username>/lumia-db
  MANIFEST_REPO: git@github.com:<your-github-username>/Project-4-Deploy-to-EKS-manifest.git
```

Also update the `sed` lines in the `update-manifests` job to match the same image names.

---

### Step 3 — Create a Docker Hub Access Token

The pipeline uses a token (not your password) to log in to Docker Hub.

1. Log in to [hub.docker.com](https://hub.docker.com)
2. Click your profile icon → **Account Settings**
3. Go to **Security** → **New Access Token**
4. Give it a name (e.g., `github-actions-lumiatech`), set permissions to **Read, Write, Delete**
5. Click **Generate** and **copy the token now** — it is shown only once

Keep this token ready for Step 5.

---

### Step 4 — Generate an SSH Deploy Key for the Manifest Repo

The pipeline clones the manifest repo and pushes tag updates back to it using SSH. You need a key pair where:
- The **private key** goes into GitHub secrets of this (app) repo
- The **public key** goes into the manifest repo as a deploy key with write access

Run this on your local machine:

```bash
ssh-keygen -t ed25519 -C "github-actions-lumiatech" -f manifest_deploy_key -N ""
```

This creates two files:
- `manifest_deploy_key` — **private key** (keep this secret)
- `manifest_deploy_key.pub` — **public key**

---

### Step 5 — Add the Public Key to the Manifest Repo

1. Open your manifest repo on GitHub: `https://github.com/<your-username>/Project-4-Deploy-to-EKS-manifest`
2. Go to **Settings** → **Deploy keys** → **Add deploy key**
3. Title: `github-actions-lumiatech`
4. Key: paste the contents of `manifest_deploy_key.pub`
5. Check **Allow write access**
6. Click **Add key**

---

### Step 6 — Add GitHub Actions Secrets to the App Repo

Go to the **app repo** on GitHub → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Add these three secrets:

| Secret Name             | Value                                                      |
|-------------------------|------------------------------------------------------------|
| `DOCKERHUB_USERNAME`    | Your Docker Hub username (e.g. `ndzenyuy`)                 |
| `DOCKERHUB_TOKEN`       | The Docker Hub access token you generated in Step 3        |
| `MANIFEST_REPO_SSH_KEY` | The full contents of the `manifest_deploy_key` private key |

To get the private key contents:

```bash
cat manifest_deploy_key
```

Copy everything including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines.

> After adding the secrets, delete `manifest_deploy_key` and `manifest_deploy_key.pub` from your local machine — they are no longer needed there.

---

### Step 7 — Provision the EKS Cluster

Cluster setup is handled in the manifest repo. Follow the instructions in [Project-4-Deploy-to-EKS-manifest](https://github.com/Ndzenyuy/Project-4-Deploy-to-EKS-manifest) to provision the EKS cluster. The typical approach uses `eksctl`:

```bash
eksctl create cluster \
  --name lumiatechs-eks-cluster \
  --region us-east-1 \
  --nodegroup-name lumiatech-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed
```

Once the cluster is up, verify access:

```bash
aws eks update-kubeconfig --name lumiatechs-eks-cluster --region us-east-1
kubectl get nodes
```

---

### Step 8 — Install the AWS EBS CSI Driver

Both of these must be in place before deploying the application.

### 8a. NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/aws/deploy.yaml

# Wait until the controller pod is running
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Confirm a Load Balancer hostname has been assigned
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

The `EXTERNAL-IP` column will show an AWS NLB hostname — note this for later.

### 8b. AWS EBS CSI Driver

Required for the MySQL PersistentVolumeClaim to bind. Without it the database pod will stay in `Pending` forever.

```bash
bash eks-setup/install-ebs-csi.sh

# Verify the driver pods are running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# Verify the gp2 storage class is available
kubectl get storageclass
```

---

### Step 9 — Install ArgoCD on the EKS Cluster

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side \
  --force-conflicts

```

Wait for all pods to be running:

```bash
kubectl get pods -n argocd
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Expose the ArgoCD UI via a LoadBalancer service:

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'
```

Wait for the external hostname to be assigned (1-2 minutes):

```bash
kubectl get svc argocd-server -n argocd
```

Once `EXTERNAL-IP` shows a hostname, open it in your browser:

```bash
ARGOCD_HOST=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://${ARGOCD_HOST}"
```

Open `http://<EXTERNAL-IP-or-hostname>` and log in with username `admin` and the password retrieved above.

---

### Step 10 — Create the ArgoCD Application

In the ArgoCD UI:

1. Click **New App**
2. Fill in the following:

| Field                    | Value                                                                  |
|--------------------------|------------------------------------------------------------------------|
| **Application Name**     | `lumiatech`                                                            |
| **Project**              | `default`                                                              |
| **Sync Policy**          | Automatic (enable **Prune Resources** and **Self Heal**)               |
| **Repository URL**       | `https://github.com/<your-username>/Project-4-Deploy-to-EKS-manifest` |
| **Revision**             | `main`                                                                 |
| **Path**                 | `helm/lumiatech`                                                       |
| **Cluster URL**          | `https://kubernetes.default.svc`                                       |
| **Namespace**            | `lumiatech` (or `default`)                                             |
| **Helm Values Files**    | `values.yaml`                                                          |

3. Click **Create**

ArgoCD will immediately sync the cluster to the current state of the manifest repo.

Alternatively, create the application via the CLI. First log in to ArgoCD using the LoadBalancer hostname:

```bash
ARGOCD_HOST=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 -d)

argocd login "${ARGOCD_HOST}" \
  --username admin \
  --password "${ARGOCD_PASS}" \
  --insecure
```

Then create the application:

```bash
argocd app create lumiatech \
  --repo https://github.com/<your-username>/Project-4-Deploy-to-EKS-manifest \
  --path helm/lumiatech \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace lumiatech \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

---

### Step 11 — Trigger Your First Deployment

Push any change to the `main` branch of this app repo to trigger the CI pipeline:

```bash
git commit --allow-empty -m "ci: trigger initial deployment"
git push origin main
```

Watch the pipeline run under **Actions** in the GitHub UI. When it completes:

1. Job 1 pushes new Docker images to Docker Hub tagged with the git SHA
2. Job 2 commits the new SHA into `helm/lumiatech/values.yaml` in the manifest repo
3. ArgoCD detects the commit and rolls out the new pods

Check the rollout:

```bash
kubectl get pods -n lumiatech -w
kubectl get svc  -n lumiatech
```

---

### Step 12 — Configure DNS (Route53 CNAME for www.lumiatechs.com)

Once the ingress controller has an external hostname, point your domain at it by running the automated CNAME setup script:

```bash
# Run from the project root — requires AWS credentials and kubeconfig in scope
bash "eks setup/06-setup-cname.sh"
```

The script performs the following in order, with full pre-flight validation at every stage:

| # | Action | Guard |
|---|--------|-------|
| 0 | Verify `kubectl`, `aws`, `curl` are installed and AWS credentials are valid | Exits early if any check fails |
| 1 | Ensure namespace `lumiatech` exists; set kubeconfig default namespace | |
| 2 | Apply all manifests from `kubedefs/` | Logs warnings but continues |
| 3 | Wait up to 180 s for all pods to reach `Running` | Exits with pod status on timeout |
| 4 | Discover the ingress-nginx LoadBalancer hostname (probes three common service names/namespaces) | Exits if the LB exposes a bare IP — CNAME requires a hostname |
| 5 | Look up the Route53 hosted zone for `lumiatechs.com` | Prints available zones and manual steps if not found |
| 6 | **Detect existing record type conflict** — if `www.lumiatechs.com` already has an A record, DELETE it before creating the CNAME (Route53 rejects an UPSERT that changes record type) | |
| 7 | UPSERT CNAME `www.lumiatechs.com → <lb-hostname>` with TTL 300 | Exits with manual instructions on failure |
| 8 | Poll `get-change` until Route53 reports `INSYNC` | |
| 9 | Apply `kubedefs/appingress.yaml` and verify the ingress host matches the domain | Warns if there is a mismatch |
| 10 | Wait 60 s, then test DNS resolution against Google (8.8.8.8) and Cloudflare (1.1.1.1) | Falls back to `nslookup` if `dig` is absent |
| 11 | Verify HTTP access via Host-header test and direct domain request | |

If the hosted zone is not found, the script prints the exact manual steps for the AWS Console.

After the script completes, verify the record:

```bash
nslookup www.lumiatechs.com
dig www.lumiatechs.com
curl -I http://www.lumiatechs.com
```

> DNS changes can take 5–10 minutes to propagate globally even after Route53 reports INSYNC. If the domain is not accessible immediately, wait and retry.

---

### Step 13 — Access the Running Application

Get the external address of the app service (LoadBalancer or Ingress, as configured in the manifest repo):

```bash
kubectl get svc -n lumiatech
```

Open `http://www.lumiatechs.com` (or the `EXTERNAL-IP` / hostname directly) in a browser. The default admin credentials for the app are:

| Username   | Password   |
|------------|------------|
| `admin_vp` | `admin_vp` |

---

### Step 14 — Local Development with Docker Compose

To run the full stack locally without any cloud dependencies:

```bash
# From the Docker-files/ directory
cd Docker-files
docker compose up --build
```

| Service   | Port |
|-----------|------|
| Nginx     | 80   |
| Tomcat    | 8080 |
| MySQL     | 3306 |
| Memcached | 11211|
| RabbitMQ  | 5672 |

The app is available at `http://localhost`. Log in with `admin_vp` / `admin_vp`.

To rebuild just the app after a code change:

```bash
# From repo root — rebuild WAR first, then restart the app container
mvn clean package -DskipTests
cd Docker-files && docker compose up --build vproapp
```

---

## Building the WAR Manually

```bash
# Build (skip tests)
mvn clean package -DskipTests

# Build (with tests)
mvn clean package

# Run a single test class
mvn test -Dtest=ClassName
```

Output: `target/lumiatech-v1.war`

---

## Building and Pushing Docker Images Manually

Use this to push images outside of the CI pipeline:

```bash
mvn clean package -DskipTests

docker build -t <dockerhub-username>/lumia-app:latest -f Docker-files/app/Dockerfile .
docker build -t <dockerhub-username>/lumia-db:latest  -f Docker-files/db/Dockerfile  Docker-files/db/

docker push <dockerhub-username>/lumia-app:latest
docker push <dockerhub-username>/lumia-db:latest
```

---

## Repository Structure

```
.
├── .github/workflows/
│   └── build-and-update.yml          # CI/CD pipeline
├── Docker-files/
│   ├── app/Dockerfile                # Tomcat 10 app image
│   ├── db/Dockerfile                 # MySQL image with seed data
│   ├── web/Dockerfile                # Nginx reverse proxy (local dev only)
│   └── docker-compose.yml            # Local dev stack
├── eks setup/
│   ├── 00-install-tools.sh           # Install kubectl, eksctl, helm, argocd CLI
│   ├── 01-create-cluster.sh          # Provision EKS cluster with eksctl
│   ├── 01b-install-ebs-csi-driver.sh # Add EBS CSI driver (required for PVCs)
│   ├── 02-install-argocd.sh          # Deploy ArgoCD into the cluster
│   ├── 03-create-argocd-app.sh       # Register the lumiatech app in ArgoCD
│   ├── 04-generate-deploy-key.sh     # Create ed25519 deploy key for manifest repo
│   ├── 05-trigger-deployment.sh      # Empty-commit push to kick off CI pipeline
│   ├── 06-setup-cname.sh             # Route53 CNAME → ingress LB + DNS verification
│   └── 99-destroy-all.sh             # Tear down cluster and all AWS resources
└── src/                              # Java Spring MVC source code
```

---

## Related Repository

Kubernetes manifests (Helm chart) and EKS cluster provisioning:  
**[Project-4-Deploy-to-EKS-manifest](https://github.com/Ndzenyuy/Project-4-Deploy-to-EKS-manifest)**
