# Rails + PostgreSQL + Redis + Skaffold Design

## Overview

A full-stack Rails 8 example app demonstrating how to use Skaffold to manage infrastructure dependencies (PostgreSQL and Redis) running in a local Kubernetes cluster (Docker Desktop), while the Rails app itself runs locally.

## Architecture

```
Developer machine
├── rails server (local, port 3000)
│   ├── connects to PostgreSQL → localhost:5432
│   └── connects to Redis      → localhost:6379
└── skaffold dev
    └── deploys → Docker Desktop k8s cluster
        ├── Helm release: postgres → Service (NodePort 5432)
        └── Helm release: redis    → Service (NodePort 6379)
```

- `skaffold dev` deploys both Bitnami Helm charts to the local k8s cluster
- Both services are exposed as NodePort, reachable at `localhost` from the host machine
- Rails runs locally via `rails server` and connects to both services using ENV vars with sensible defaults
- `ctrl-c` on `skaffold dev` tears down both services cleanly

## Project Structure

```
postgres-rails/
├── app/
│   ├── controllers/
│   │   └── posts_controller.rb   # full CRUD actions
│   ├── models/
│   │   └── post.rb               # title, body with presence validations
│   └── views/
│       └── posts/                # index, show, new, edit, _form
├── config/
│   └── database.yml              # ENV-driven, defaults to localhost:5432
├── db/
│   └── migrate/
│       └── XXXXXX_create_posts.rb
├── charts/
│   ├── postgres/
│   │   ├── Chart.yaml            # wrapper chart, Bitnami postgres as dependency
│   │   └── values.yaml           # NodePort 5432, fixed credentials
│   └── redis/
│       ├── Chart.yaml            # wrapper chart, Bitnami redis as dependency
│       └── values.yaml           # NodePort 6379, no auth
├── skaffold.yaml                 # helm deployer only, no build section
└── Gemfile
```

## Rails App

- **Ruby 3.3, Rails 8**
- **Resource:** Posts with `title:string` and `body:text`
- **Routes:** `resources :posts`, root set to `posts#index`
- **Validations:** presence of `title` and `body`
- **Views:** Standard ERB scaffold (index, show, new, edit, _form partial)
- **Caching:** Redis cache store configured in `config/environments/development.rb`

### database.yml

```yaml
default: &default
  adapter: postgresql
  host: <%= ENV.fetch("DB_HOST", "localhost") %>
  port: <%= ENV.fetch("DB_PORT", 5432) %>
  username: <%= ENV.fetch("DB_USERNAME", "postgres") %>
  password: <%= ENV.fetch("DB_PASSWORD", "password") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
  timeout: 5000

development:
  <<: *default
  database: postgres_rails_development

test:
  <<: *default
  database: postgres_rails_test
```

### Cache Store (development.rb)

```ruby
config.cache_store = :redis_cache_store, {
  url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
}
```

### Gemfile additions

- `gem "redis"` — Redis client for cache store

## Helm Charts

Both charts are thin wrappers that declare the Bitnami chart as a dependency, keeping custom values in the repo.

### charts/postgres/Chart.yaml

```yaml
apiVersion: v2
name: postgres
version: 0.1.0
dependencies:
  - name: postgresql
    version: "~18"
    repository: https://charts.bitnami.com/bitnami
```

### charts/postgres/values.yaml

```yaml
postgresql:
  auth:
    username: postgres
    password: password
    database: postgres_rails_development
  primary:
    service:
      type: NodePort
      nodePorts:
        postgresql: "5432"
```

### charts/redis/Chart.yaml

```yaml
apiVersion: v2
name: redis
version: 0.1.0
dependencies:
  - name: redis
    version: "~20"
    repository: https://charts.bitnami.com/bitnami
```

### charts/redis/values.yaml

```yaml
redis:
  auth:
    enabled: false
  master:
    service:
      type: NodePort
      nodePorts:
        redis: "6379"
```

## Skaffold Configuration

```yaml
apiVersion: skaffold/v4beta11
deploy:
  helm:
    releases:
      - name: postgres
        chartPath: charts/postgres
        valuesFiles:
          - charts/postgres/values.yaml
        namespace: default
        createNamespace: true
      - name: redis
        chartPath: charts/redis
        valuesFiles:
          - charts/redis/values.yaml
        namespace: default
        createNamespace: true
```

No `build` section — Skaffold only manages Helm deployments.

## Developer Workflow

```bash
# Terminal 1 — start infrastructure
skaffold dev

# Terminal 2 — run Rails
bundle install
rails db:create db:migrate
rails server
# → open http://localhost:3000
```

## Out of Scope

- Production deployment configuration
- TLS / secrets management
- Authentication / authorization
- Docker image for the Rails app
- CI/CD pipeline
