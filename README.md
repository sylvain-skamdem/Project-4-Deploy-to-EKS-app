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
```

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
  --name lumiatech-cluster \
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
aws eks update-kubeconfig --name lumiatech-cluster --region us-east-1
kubectl get nodes
```

---

### Step 8 — Install ArgoCD on the EKS Cluster

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to be running:

```bash
kubectl get pods -n argocd -w
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Expose the ArgoCD UI (for initial access; use an Ingress or LoadBalancer in production):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` and log in with username `admin` and the password retrieved above.

---

### Step 9 — Create the ArgoCD Application

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

Alternatively, create the application via the CLI:

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

### Step 10 — Trigger Your First Deployment

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

### Step 11 — Access the Running Application

Get the external address of the app service (LoadBalancer or Ingress, as configured in the manifest repo):

```bash
kubectl get svc -n lumiatech
```

Open the `EXTERNAL-IP` or hostname in a browser. The default admin credentials for the app are:

| Username   | Password   |
|------------|------------|
| `admin_vp` | `admin_vp` |

---

### Step 12 — Local Development with Docker Compose

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
│   └── build-and-update.yml    # CI/CD pipeline
├── Docker-files/
│   ├── app/Dockerfile          # Tomcat 10 app image
│   ├── db/Dockerfile           # MySQL image with seed data
│   ├── web/Dockerfile          # Nginx reverse proxy (local dev only)
│   └── docker-compose.yml      # Local dev stack
└── src/                        # Java Spring MVC source code
```

---

## Related Repository

Kubernetes manifests (Helm chart) and EKS cluster provisioning:  
**[Project-4-Deploy-to-EKS-manifest](https://github.com/Ndzenyuy/Project-4-Deploy-to-EKS-manifest)**
