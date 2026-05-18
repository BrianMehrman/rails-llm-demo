# Custom Helm Charts (Postgres + Redis StatefulSets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Bitnami dependency-based Helm charts with hand-written charts that deploy PostgreSQL and Redis as StatefulSets backed by configurable storage (hostPath by default, PVC when enabled).

**Architecture:** Each chart is self-contained — no external chart dependencies. Storage is controlled by a single boolean toggle: `storage.pvc.enabled`. When false (default), a `hostPath` volume on the local node is used. When true, a `volumeClaimTemplate` creates a PVC per pod. Both charts expose their service as a NodePort on the same ports as before (5432, 6379).

**Tech Stack:** Helm 3, Kubernetes StatefulSet, Kubernetes Service (NodePort), official `postgres:16-alpine` and `redis:7-alpine` images

---

## File Map

### Postgres chart

| File | Action | Purpose |
|------|--------|---------|
| `charts/postgres/Chart.yaml` | Rewrite | Remove dependency, keep metadata |
| `charts/postgres/Chart.lock` | Delete (git rm) | No longer needed without dependencies |
| `charts/postgres/values.yaml` | Rewrite | New schema: image, auth, service, storage |
| `charts/postgres/templates/_helpers.tpl` | Create | Helm name/label helpers |
| `charts/postgres/templates/statefulset.yaml` | Create | StatefulSet with conditional hostPath vs PVC |
| `charts/postgres/templates/service.yaml` | Create | NodePort service on 5432 |

### Redis chart

| File | Action | Purpose |
|------|--------|---------|
| `charts/redis/Chart.yaml` | Rewrite | Remove dependency, keep metadata |
| `charts/redis/Chart.lock` | Delete (git rm) | No longer needed without dependencies |
| `charts/redis/values.yaml` | Rewrite | New schema: image, service, storage |
| `charts/redis/templates/_helpers.tpl` | Create | Helm name/label helpers |
| `charts/redis/templates/statefulset.yaml` | Create | StatefulSet with conditional hostPath vs PVC |
| `charts/redis/templates/service.yaml` | Create | NodePort service on 6379 |

---

### Task 1: Rebuild the Postgres Helm chart

**Files:**
- Rewrite: `charts/postgres/Chart.yaml`
- Delete: `charts/postgres/Chart.lock`
- Rewrite: `charts/postgres/values.yaml`
- Create: `charts/postgres/templates/_helpers.tpl`
- Create: `charts/postgres/templates/statefulset.yaml`
- Create: `charts/postgres/templates/service.yaml`

- [ ] **Step 1: Remove old dependency artifacts**

```bash
git rm charts/postgres/Chart.lock
rm -rf charts/postgres/charts/
```

Expected: `Chart.lock` removed from git, the `charts/postgres/charts/` directory (containing the Bitnami tarballs and extracted chart) is deleted from disk.

- [ ] **Step 2: Rewrite charts/postgres/Chart.yaml**

Replace the entire file with:

```yaml
apiVersion: v2
name: postgres
description: Custom PostgreSQL chart for local development
type: application
version: 0.1.0
```

- [ ] **Step 3: Rewrite charts/postgres/values.yaml**

Replace the entire file with:

```yaml
image:
  repository: postgres
  tag: "16-alpine"

auth:
  username: postgres
  password: password
  database: postgres_rails_development

service:
  type: NodePort
  port: 5432
  nodePort: 5432

storage:
  # Used when storage.pvc.enabled is false (default for local development)
  hostPath: /tmp/postgres-rails/postgres
  pvc:
    enabled: false
    storageClass: ""
    size: 1Gi
```

- [ ] **Step 4: Create the templates directory**

```bash
mkdir -p charts/postgres/templates
```

- [ ] **Step 5: Create charts/postgres/templates/_helpers.tpl**

```
{{- define "postgres.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postgres.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "postgres.labels" -}}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

- [ ] **Step 6: Create charts/postgres/templates/statefulset.yaml**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "postgres.fullname" . }}
  labels:
    {{- include "postgres.labels" . | nindent 4 }}
spec:
  serviceName: {{ include "postgres.fullname" . }}
  replicas: 1
  selector:
    matchLabels:
      {{- include "postgres.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "postgres.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: postgres
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - name: postgresql
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: {{ .Values.auth.username | quote }}
            - name: POSTGRES_PASSWORD
              value: {{ .Values.auth.password | quote }}
            - name: POSTGRES_DB
              value: {{ .Values.auth.database | quote }}
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      {{- if not .Values.storage.pvc.enabled }}
      volumes:
        - name: data
          hostPath:
            path: {{ .Values.storage.hostPath }}
            type: DirectoryOrCreate
      {{- end }}
  {{- if .Values.storage.pvc.enabled }}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- if .Values.storage.pvc.storageClass }}
        storageClassName: {{ .Values.storage.pvc.storageClass | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.storage.pvc.size }}
  {{- end }}
```

Note: `PGDATA` is set to a subdirectory (`pgdata`) inside the mount point. This avoids Postgres errors when the hostPath directory already exists and is not empty — Postgres requires its data directory to be either empty or a valid database.

- [ ] **Step 7: Create charts/postgres/templates/service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "postgres.fullname" . }}
  labels:
    {{- include "postgres.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "postgres.selectorLabels" . | nindent 4 }}
  ports:
    - name: postgresql
      port: {{ .Values.service.port }}
      targetPort: postgresql
      {{- if eq .Values.service.type "NodePort" }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
```

- [ ] **Step 8: Lint the chart**

```bash
helm lint charts/postgres
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

If any errors appear, fix them before proceeding. Common issues:
- Indentation errors in YAML templates
- Missing `{{- end }}` closures

- [ ] **Step 9: Render the templates to verify output**

```bash
helm template test-release charts/postgres
```

Expected: valid YAML output for a StatefulSet and Service. The StatefulSet should have a `volumes` section (hostPath), not a `volumeClaimTemplates` section, since `storage.pvc.enabled` defaults to false.

Verify the rendered StatefulSet has:
- `hostPath.path: /tmp/postgres-rails/postgres`
- `PGDATA` env var set to `/var/lib/postgresql/data/pgdata`
- `image: postgres:16-alpine`

- [ ] **Step 10: Commit**

```bash
git add charts/postgres/
git commit -m "feat: replace Postgres Bitnami dependency chart with custom StatefulSet chart"
```

---

### Task 2: Rebuild the Redis Helm chart

**Files:**
- Rewrite: `charts/redis/Chart.yaml`
- Delete: `charts/redis/Chart.lock`
- Rewrite: `charts/redis/values.yaml`
- Create: `charts/redis/templates/_helpers.tpl`
- Create: `charts/redis/templates/statefulset.yaml`
- Create: `charts/redis/templates/service.yaml`

- [ ] **Step 1: Remove old dependency artifacts**

```bash
git rm charts/redis/Chart.lock
rm -rf charts/redis/charts/
```

Expected: `Chart.lock` removed from git, the `charts/redis/charts/` directory is deleted from disk.

- [ ] **Step 2: Rewrite charts/redis/Chart.yaml**

Replace the entire file with:

```yaml
apiVersion: v2
name: redis
description: Custom Redis chart for local development
type: application
version: 0.1.0
```

- [ ] **Step 3: Rewrite charts/redis/values.yaml**

Replace the entire file with:

```yaml
image:
  repository: redis
  tag: "7-alpine"

service:
  type: NodePort
  port: 6379
  nodePort: 6379

storage:
  # Used when storage.pvc.enabled is false (default for local development)
  hostPath: /tmp/postgres-rails/redis
  pvc:
    enabled: false
    storageClass: ""
    size: 512Mi
```

- [ ] **Step 4: Create the templates directory**

```bash
mkdir -p charts/redis/templates
```

- [ ] **Step 5: Create charts/redis/templates/_helpers.tpl**

```
{{- define "redis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "redis.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "redis.labels" -}}
app.kubernetes.io/name: {{ include "redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

- [ ] **Step 6: Create charts/redis/templates/statefulset.yaml**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "redis.fullname" . }}
  labels:
    {{- include "redis.labels" . | nindent 4 }}
spec:
  serviceName: {{ include "redis.fullname" . }}
  replicas: 1
  selector:
    matchLabels:
      {{- include "redis.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "redis.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: redis
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["redis-server", "--appendonly", "yes", "--dir", "/data"]
          ports:
            - name: redis
              containerPort: 6379
          volumeMounts:
            - name: data
              mountPath: /data
      {{- if not .Values.storage.pvc.enabled }}
      volumes:
        - name: data
          hostPath:
            path: {{ .Values.storage.hostPath }}
            type: DirectoryOrCreate
      {{- end }}
  {{- if .Values.storage.pvc.enabled }}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        {{- if .Values.storage.pvc.storageClass }}
        storageClassName: {{ .Values.storage.pvc.storageClass | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.storage.pvc.size }}
  {{- end }}
```

Note: `--appendonly yes` enables Redis persistence (AOF). `--dir /data` sets the working directory to the mounted volume so the AOF file is written there.

- [ ] **Step 7: Create charts/redis/templates/service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "redis.fullname" . }}
  labels:
    {{- include "redis.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "redis.selectorLabels" . | nindent 4 }}
  ports:
    - name: redis
      port: {{ .Values.service.port }}
      targetPort: redis
      {{- if eq .Values.service.type "NodePort" }}
      nodePort: {{ .Values.service.nodePort }}
      {{- end }}
```

- [ ] **Step 8: Lint the chart**

```bash
helm lint charts/redis
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 9: Render the templates to verify output**

```bash
helm template test-release charts/redis
```

Expected: valid YAML for a StatefulSet and Service. The StatefulSet should have:
- `hostPath.path: /tmp/postgres-rails/redis`
- `command: ["redis-server", "--appendonly", "yes", "--dir", "/data"]`
- `image: redis:7-alpine`

- [ ] **Step 10: Commit**

```bash
git add charts/redis/
git commit -m "feat: replace Redis Bitnami dependency chart with custom StatefulSet chart"
```

---

### Task 3: Verify PVC rendering (template test only)

This task verifies that the PVC toggle works correctly by rendering templates with `pvc.enabled: true` — no cluster required.

- [ ] **Step 1: Test Postgres PVC rendering**

```bash
helm template test-release charts/postgres \
  --set storage.pvc.enabled=true \
  --set storage.pvc.size=2Gi \
  --set storage.pvc.storageClass=standard
```

Verify the rendered output:
- Contains `volumeClaimTemplates:` (not `volumes:`)
- Contains `storageClassName: "standard"`
- Contains `storage: 2Gi`
- Does NOT contain `hostPath`

- [ ] **Step 2: Test Redis PVC rendering**

```bash
helm template test-release charts/redis \
  --set storage.pvc.enabled=true \
  --set storage.pvc.size=1Gi \
  --set storage.pvc.storageClass=standard
```

Verify the rendered output:
- Contains `volumeClaimTemplates:`
- Contains `storageClassName: "standard"`
- Does NOT contain `hostPath`

- [ ] **Step 3: Test that omitting storageClass works**

```bash
helm template test-release charts/postgres --set storage.pvc.enabled=true
```

Verify the rendered output:
- Contains `volumeClaimTemplates:`
- Does NOT contain `storageClassName:` (because `storageClass` defaults to empty string, which is falsy)

- [ ] **Step 4: Commit (no code changes, just verification)**

No commit needed for this task — it is verification only.

---

### Task 4: Update .gitignore

The `charts/*/charts/*.tgz` pattern in `.gitignore` was added for the Bitnami dependency tarballs. Since the charts are now self-contained with no dependencies, this pattern is obsolete. Remove it to keep `.gitignore` accurate.

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Remove the Helm tarballs entry from .gitignore**

Open `.gitignore`. Find and remove these two lines (they were added in the original chart setup):

```
# Helm downloaded chart dependencies
charts/*/charts/*.tgz
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: remove obsolete Helm dependency tarball gitignore entry"
```
