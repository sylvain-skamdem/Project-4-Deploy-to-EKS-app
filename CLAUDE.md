# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build WAR artifact (skipping tests)
mvn clean package -DskipTests

# Build WAR with tests
mvn clean package

# Run a single test class
mvn test -Dtest=ClassName

# Build and tag Docker images (run from repo root after mvn build)
docker build -t ndzenyuy/lumia-app:latest -f Docker-files/app/Dockerfile .
docker build -t ndzenyuy/lumia-db:latest  -f Docker-files/db/Dockerfile  Docker-files/db/

# Local dev stack (from Docker-files/ directory)
cd Docker-files && docker-compose up -d
```

The WAR output is `target/lumiatech-v1.war`. The app Dockerfile copies it to Tomcat's `webapps/ROOT.war`, so the app is served at `/`.

## Architecture Overview

**Application**: Spring MVC 6 / Spring Boot 3 WAR deployed on Tomcat 10 (JDK 21 runtime, JDK 17 compilation target). It is a user-management web app with BCrypt-secured form login, role-based access control, Memcached caching, RabbitMQ messaging, and Elasticsearch search.

**Spring wiring** is XML-based (not annotation `@SpringBootApplication`):
- `web.xml` boots a `ContextLoaderListener` loading `appconfig-root.xml`, which imports `appconfig-data.xml`, `appconfig-security.xml`, `appconfig-rabbitmq.xml`
- `appconfig-mvc.xml` is loaded by the `DispatcherServlet`
- Component scan covers `com.visualpathit.account.*`

**Package layout** (`src/main/java/com/visualpathit/account/`):
- `controller/` — Spring MVC controllers (User, FileUpload, RabbitMq, ElasticSearch)
- `model/` — JPA entities: `User`, `Role`
- `repository/` — Spring Data JPA interfaces
- `service/` — Interfaces + `*Impl` classes (UserService, SecurityService, ProducerService, ConsumerService)
- `utils/` — Thin wrappers around Memcached, RabbitMQ, and Elasticsearch clients
- `exception/` — `GlobalExceptionHandler`, `UserNotFoundException`, `AuthenticationFailureHandler`
- `validator/` — `UserValidator`
- `beans/` — `DatabaseConnectionMonitor`, `Components`

Views are JSPs under `src/main/webapp/WEB-INF/views/`.

**Infrastructure / deployment**:
- **CI/CD**: GitHub Actions (`.github/workflows/build-and-update.yml`) — on push to `main`, builds the WAR, builds and pushes Docker images tagged with the 7-char git SHA to Docker Hub (`ndzenyuy/lumia-app`, `ndzenyuy/lumia-db`), then clones the separate manifest repo (`git@github.com:Ndzenyuy/Project-4-Deploy-to-EKS-manifest.git`) and `sed`-patches the Helm `values.yaml` with the new SHA.
- **GitOps**: ArgoCD watches the manifest repo and rolls out updated pods to the EKS cluster automatically.
- **Local stack** (docker-compose): 5 services — `vproweb` (Nginx:80), `vproapp` (Tomcat:8080), `vprodb` (MySQL:3306), `vprocache01` (Memcached:11211), `vpromq01` (RabbitMQ:5672, guest/guest).

## Key Configuration

`src/main/resources/application.properties` contains hardcoded connection strings for all backing services. In production these point at AWS RDS (MySQL), while docker-compose uses service DNS names (`mc01`, `rmq01`, etc.). The same WAR is used for both; service hostnames must resolve at runtime.

**Required GitHub Actions secrets** for the CI pipeline:
- `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`
- `MANIFEST_REPO_SSH_KEY` (ed25519 key with write access to manifest repo)

## Local vs Production

| Service | Local (docker-compose) | Production |
|---|---|---|
| MySQL | `vprodb:3306` | AWS RDS endpoint |
| Memcached | `vprocache01:11211` | ElastiCache or in-cluster |
| RabbitMQ | `vpromq01:5672` | In-cluster or managed |
| App image | build locally | `ndzenyuy/lumia-app:<sha>` |

Spring Security default admin credentials (local only): `admin_vp` / `admin_vp`.
