# Rails + PostgreSQL + Redis + Skaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a full-stack Rails 8 app with a Posts CRUD resource, using Skaffold to manage PostgreSQL and Redis in a local Kubernetes cluster (Docker Desktop), while Rails runs locally.

**Architecture:** Skaffold deploys Bitnami PostgreSQL and Redis Helm charts to Docker Desktop k8s, exposing both via NodePort on localhost. Rails runs locally via `rails server`, connecting to both services using ENV vars with localhost defaults.

**Tech Stack:** Ruby 3.3, Rails 8, PostgreSQL (Bitnami Helm chart ~18), Redis (Bitnami Helm chart ~20), Skaffold v2, Helm 3, Docker Desktop Kubernetes, Minitest

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Gemfile` | Modify | Add `gem "redis"` |
| `config/database.yml` | Rewrite | ENV-driven connection (host/port/user/pass) |
| `config/environments/development.rb` | Modify | Redis cache store config |
| `config/routes.rb` | Modify | Add root route to `posts#index` |
| `app/models/post.rb` | Modify | Add presence validations |
| `app/controllers/posts_controller.rb` | Create (scaffold) | Full CRUD actions |
| `app/views/posts/` | Create (scaffold) | index, show, new, edit, _form views |
| `db/migrate/XXXXXX_create_posts.rb` | Create (scaffold) | Posts table migration |
| `test/models/post_test.rb` | Rewrite | Validation unit tests |
| `test/controllers/posts_controller_test.rb` | Create (scaffold) | Controller tests |
| `charts/postgres/Chart.yaml` | Create | Bitnami postgresql dependency chart |
| `charts/postgres/values.yaml` | Create | NodePort 5432, fixed credentials |
| `charts/redis/Chart.yaml` | Create | Bitnami redis dependency chart |
| `charts/redis/values.yaml` | Create | NodePort 6379, no auth, standalone mode |
| `.gitignore` | Modify | Ignore downloaded chart tarballs |
| `skaffold.yaml` | Create | Helm deployer for postgres + redis releases |

---

### Task 1: Generate the Rails application

**Files:**
- Create: all Rails app files (via `rails new`)

- [ ] **Step 1: Verify prerequisites**

```bash
ruby --version
rails --version
```

Expected: `ruby 3.3.x` and `Rails 8.x.x`

- [ ] **Step 2: Generate the Rails app in the project directory**

Run from `/Users/brianmehrman/projects/postgres-rails`:

```bash
rails new . --database=postgresql --skip-git
```

When prompted to overwrite any existing files, type `Y` to accept.

- [ ] **Step 3: Verify the app was generated**

```bash
ls app/ config/ db/ test/
```

Expected: all standard Rails directories present with files inside them.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: generate Rails 8 app with PostgreSQL adapter"
```

---

### Task 2: Configure database.yml with ENV vars

**Files:**
- Modify: `config/database.yml`

- [ ] **Step 1: Rewrite config/database.yml**

Replace the entire contents of `config/database.yml` with:

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  host: <%= ENV.fetch("DB_HOST", "localhost") %>
  port: <%= ENV.fetch("DB_PORT", 5432) %>
  username: <%= ENV.fetch("DB_USERNAME", "postgres") %>
  password: <%= ENV.fetch("DB_PASSWORD", "password") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>

development:
  <<: *default
  database: postgres_rails_development

test:
  <<: *default
  database: postgres_rails_test

production:
  <<: *default
  database: postgres_rails_production
  username: <%= ENV["DB_USERNAME"] %>
  password: <%= ENV["DB_PASSWORD"] %>
```

- [ ] **Step 2: Commit**

```bash
git add config/database.yml
git commit -m "feat: configure database.yml with ENV-driven connection settings"
```

---

### Task 3: Add Redis gem and configure cache store

**Files:**
- Modify: `Gemfile`
- Modify: `config/environments/development.rb`

- [ ] **Step 1: Add redis gem to Gemfile**

Open `Gemfile`. Add this line in the main gem block (after the `rails` gem line):

```ruby
gem "redis"
```

- [ ] **Step 2: Install the gem**

```bash
bundle install
```

Expected: `Bundle complete!` — verify `redis` appears in the output.

- [ ] **Step 3: Update the cache store in development.rb**

Open `config/environments/development.rb`. Find this block (it will look similar to this):

```ruby
if Rails.root.join("tmp/caching-dev.txt").exist?
  config.action_controller.perform_caching = true
  config.action_controller.enable_fragment_cache_logging = true
  config.cache_store = :memory_store
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{2.days.to_i}"
  }
else
  config.action_controller.perform_caching = false
  config.cache_store = :null_store
end
```

Replace it with:

```ruby
if Rails.root.join("tmp/caching-dev.txt").exist?
  config.action_controller.perform_caching = true
  config.action_controller.enable_fragment_cache_logging = true
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  }
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{2.days.to_i}"
  }
else
  config.action_controller.perform_caching = false
  config.cache_store = :null_store
end
```

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock config/environments/development.rb
git commit -m "feat: add Redis gem and configure redis_cache_store for development"
```

---

### Task 4: Generate Posts scaffold

**Files:**
- Create: `app/models/post.rb`
- Create: `app/controllers/posts_controller.rb`
- Create: `app/views/posts/` (index, show, new, edit, _form)
- Create: `db/migrate/XXXXXX_create_posts.rb`
- Create: `test/models/post_test.rb`
- Create: `test/controllers/posts_controller_test.rb`
- Create: `test/system/posts_test.rb`

- [ ] **Step 1: Generate the scaffold**

```bash
rails generate scaffold Post title:string body:text
```

Expected output includes lines like:
```
create  db/migrate/XXXXXX_create_posts.rb
create  app/models/post.rb
create  app/controllers/posts_controller.rb
create  app/views/posts/...
create  test/models/post_test.rb
create  test/controllers/posts_controller_test.rb
```

- [ ] **Step 2: Commit the generated scaffold**

```bash
git add -A
git commit -m "feat: generate Posts scaffold with title:string and body:text"
```

---

### Task 5: Set root route

**Files:**
- Modify: `config/routes.rb`

- [ ] **Step 1: Add root route**

Open `config/routes.rb`. The scaffold already added `resources :posts`. Add the root route so the file looks like:

```ruby
Rails.application.routes.draw do
  resources :posts
  root "posts#index"
end
```

- [ ] **Step 2: Commit**

```bash
git add config/routes.rb
git commit -m "feat: set root route to posts#index"
```

---

### Task 6: Create Postgres Helm chart

**Files:**
- Create: `charts/postgres/Chart.yaml`
- Create: `charts/postgres/values.yaml`
- Modify: `.gitignore`

- [ ] **Step 1: Create chart directory**

```bash
mkdir -p charts/postgres
```

- [ ] **Step 2: Create charts/postgres/Chart.yaml**

```yaml
apiVersion: v2
name: postgres
description: PostgreSQL dependency chart for local development
type: application
version: 0.1.0
dependencies:
  - name: postgresql
    version: "~18"
    repository: https://charts.bitnami.com/bitnami
```

- [ ] **Step 3: Create charts/postgres/values.yaml**

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

- [ ] **Step 4: Add Bitnami repo and pull dependencies**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update charts/postgres
```

Expected: `charts/postgres/Chart.lock` is created and `charts/postgres/charts/postgresql-*.tgz` is downloaded.

- [ ] **Step 5: Gitignore downloaded chart tarballs**

Open `.gitignore` and add at the bottom:

```
# Helm downloaded chart dependencies
charts/*/charts/*.tgz
```

- [ ] **Step 6: Commit**

```bash
git add charts/postgres/ .gitignore
git commit -m "feat: add Postgres Helm wrapper chart for local k8s development"
```

---

### Task 7: Create Redis Helm chart

**Files:**
- Create: `charts/redis/Chart.yaml`
- Create: `charts/redis/values.yaml`

- [ ] **Step 1: Create chart directory**

```bash
mkdir -p charts/redis
```

- [ ] **Step 2: Create charts/redis/Chart.yaml**

```yaml
apiVersion: v2
name: redis
description: Redis dependency chart for local development
type: application
version: 0.1.0
dependencies:
  - name: redis
    version: "~20"
    repository: https://charts.bitnami.com/bitnami
```

- [ ] **Step 3: Create charts/redis/values.yaml**

```yaml
redis:
  architecture: standalone
  auth:
    enabled: false
  master:
    service:
      type: NodePort
      nodePorts:
        redis: "6379"
```

- [ ] **Step 4: Pull dependencies**

```bash
helm dependency update charts/redis
```

Expected: `charts/redis/Chart.lock` created and `charts/redis/charts/redis-*.tgz` downloaded.

- [ ] **Step 5: Commit**

```bash
git add charts/redis/
git commit -m "feat: add Redis Helm wrapper chart for local k8s development"
```

---

### Task 8: Create skaffold.yaml

**Files:**
- Create: `skaffold.yaml`

- [ ] **Step 1: Create skaffold.yaml in the project root**

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

- [ ] **Step 2: Verify skaffold recognizes the config**

```bash
skaffold version
skaffold diagnose
```

Expected: no errors. Skaffold should list both Helm releases.

- [ ] **Step 3: Commit**

```bash
git add skaffold.yaml
git commit -m "feat: add skaffold.yaml to manage Postgres and Redis via Helm"
```

---

### Task 9: Write and pass Post model validation tests (TDD)

**Files:**
- Rewrite: `test/models/post_test.rb`
- Modify: `app/models/post.rb`

This task requires Postgres to be running. Start it first (Terminal 1):

```bash
skaffold dev
```

Wait until both releases show as deployed, then continue in Terminal 2.

- [ ] **Step 1: Create and migrate the database**

```bash
rails db:create db:migrate
```

Expected:
```
Created database 'postgres_rails_development'
Created database 'postgres_rails_test'
```

- [ ] **Step 2: Write failing validation tests**

Replace the contents of `test/models/post_test.rb` with:

```ruby
require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "is valid with title and body" do
    post = Post.new(title: "Hello", body: "World")
    assert post.valid?
  end

  test "is invalid without title" do
    post = Post.new(body: "World")
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "is invalid without body" do
    post = Post.new(title: "Hello")
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end
end
```

- [ ] **Step 3: Run tests and verify they fail**

```bash
rails test test/models/post_test.rb
```

Expected: 2 failures — `is invalid without title` and `is invalid without body` both fail because the model has no validations yet.

- [ ] **Step 4: Add validations to the Post model**

Open `app/models/post.rb` and replace its contents with:

```ruby
class Post < ApplicationRecord
  validates :title, presence: true
  validates :body, presence: true
end
```

- [ ] **Step 5: Run tests and verify they pass**

```bash
rails test test/models/post_test.rb
```

Expected: `3 runs, 0 failures, 0 errors`.

- [ ] **Step 6: Commit**

```bash
git add app/models/post.rb test/models/post_test.rb
git commit -m "feat: add presence validations to Post with failing-then-passing tests"
```

---

### Task 10: Run generated controller tests

**Files:**
- Read: `test/controllers/posts_controller_test.rb` (generated by scaffold, no changes needed)

- [ ] **Step 1: Run the scaffold-generated controller tests**

```bash
rails test test/controllers/posts_controller_test.rb
```

Expected: all tests pass. The scaffold generates tests that correspond to the CRUD actions.

If tests fail due to missing fixtures, open `test/fixtures/posts.yml` and verify it has at least one fixture entry (the scaffold generates these automatically).

- [ ] **Step 2: Run the full test suite**

```bash
rails test
```

Expected: all tests pass, 0 failures, 0 errors.

- [ ] **Step 3: Commit if any fixture adjustments were made**

Only commit if you had to change fixtures:

```bash
git add test/fixtures/posts.yml
git commit -m "fix: update posts fixtures for controller tests"
```

---

### Task 11: End-to-end verification

- [ ] **Step 1: Confirm infrastructure is running**

In Terminal 1 (if not already running):

```bash
skaffold dev
```

Verify both releases are deployed:

```bash
kubectl get pods
```

Expected: pods like `postgres-postgresql-0` and `redis-master-0` in Running state.

- [ ] **Step 2: Confirm services are exposed on expected ports**

```bash
kubectl get svc
```

Expected output includes:
- `postgres-postgresql` with `NodePort` and port `5432`
- `redis-master` with `NodePort` and port `6379`

- [ ] **Step 3: Start Rails server**

In Terminal 2:

```bash
rails server
```

Expected: server starts on `http://localhost:3000`.

- [ ] **Step 4: Verify Posts CRUD in browser**

Open `http://localhost:3000`. Verify:
1. Posts index page loads with "No posts yet" or empty list
2. Click "New Post" — form appears with Title and Body fields
3. Submit empty form — validation errors appear for both fields
4. Fill in both fields and submit — post is created and shown
5. Edit the post and save — changes persist
6. Delete the post — post is removed from the list

- [ ] **Step 5: Verify Redis caching is configured**

```bash
rails dev:cache
```

Expected: `Development mode is now being cached.`

Restart Rails server (`ctrl-c` then `rails server` again). The app now uses `redis_cache_store` with `redis://localhost:6379/0`.

- [ ] **Step 6: Stop infrastructure**

Press `ctrl-c` in Terminal 1 to stop `skaffold dev`. Skaffold tears down both Helm releases from the cluster.
