# arcanna-helm

Helm charts for deploying Arcanna on Kubernetes (bare-metal RKE2, GKE, or anywhere else).

## One-line installer

```bash
git clone https://github.com/siscale/arcanna-helm
cd arcanna-helm
cp .env.example .env
vim .env                    # set ENV, STORAGE_CLASS, GCR_JSON_KEY_FILE; rest can stay empty
make deploy-all
```

On first run, if `envs/$ENV/` doesn't exist, the Makefile auto-creates it from
`envs/_template/` using your `.env` values. Those files stay on disk — commit
them, edit them, whatever. Running `make deploy-all` a second time just reuses
what's there.

## How it works

**`.env`** is the single source of per-installation config — cluster target,
storage class, NodePorts, image tags, GCR key, optional URLs. The Makefile
auto-includes it (`-include .env` + `export`). Passwords and URLs left empty
get auto-generated / auto-detected at deploy time.

**`envs/_template/`** holds generic env files with `@PLACEHOLDER@` tokens
(`@ES_CLUSTER_NAME@`, `@STORAGE_CLASS@`, `@PLATFORM_NODE_PORT@`, `@EXPOSER_NODE_PORT@`,
`@ENV_NAME@`). `make init-env` copies the template into `envs/$ENV/` and
substitutes placeholders from `.env`.

**`envs/<name>/_common.yaml`** holds env-wide shared values (ES endpoint,
Kibana URL, log storage class) so you don't duplicate them across 14 files.
Loaded before every chart-specific file.

**`envs/<name>/*.yaml`** — per-chart overrides. Fine to edit directly;
`init-env` is idempotent and won't overwrite your changes.

## Workflows

### Fresh install on a new cluster

```bash
cp .env.example .env
# Edit .env: set ENV, STORAGE_CLASS, ES_CLUSTER_NAME, GCR_JSON_KEY_FILE.
# Leave BACKEND_URL / MONITORING_URL empty for NodePort-only mode.
make deploy-all
```

8 phases run in order: namespace → secrets (auto-gen PG/Redis creds) →
ES/Kafka/PG/Redis/Kibana → main-config → migration start → core services
(rest-api, core-framework, hypervisor, exposer, agents-exposer, feedbacker,
remote-llm, mcp-client) → workers + processing → monitoring → migration end
→ frontend. The auto-generated DB passwords are printed once — save them.

### Upgrading to a new Arcanna version

```bash
cd arcanna-helm
git pull                    # pick up chart + template improvements

# Optional: see if the template changed in ways that affect your env
make diff-env ENV=my-env

# Bump image tags in .env (TAG applies to all unless you override per-service)
vim .env                    # TAG = v1.79.0

make upgrade-all
```

`upgrade-all` reruns `helm upgrade` for every app service (no infra touches,
no secret regeneration) with the new tags. PostgreSQL/Redis/ES data is
untouched. Migration jobs run before and after to handle schema changes.

### Adopting template improvements into your env

When `git pull` brings in changes to `envs/_template/*.yaml` (new config keys,
tweaks to defaults), your `envs/$ENV/` doesn't auto-update — that's intentional,
your customizations are sacred. `make diff-env` shows exactly what changed.
Copy across what you want manually, or:

```bash
make reset-env ENV=my-env   # requires typing the env name to confirm
make init-env               # regenerates from current template + .env
# then re-apply your local customizations
```

### Deploying to multiple envs on the same cluster

Each env uses different NodePorts (set in its `.env`) and different ES
cluster names (so ECK creates separate `<name>-es-http` services).
Just run `make deploy-all` with a different `.env` per install, or override
inline: `make deploy-all ENV=arcanna-e2e NAMESPACE=arcanna-e2e`.

### Individual component redeploy

```bash
make deploy-postgres                                          # uses .env
make deploy-rest-api HELM_EXTRA_ARGS='--set image.tag=abc123' # inline override
make deploy-hypervisor MODULAR_TAG=v1.78.1
```

### GPU node for arcanna-rag

Not part of `deploy-all` — manual, typically needs a GPU node:

```bash
make deploy-arcanna-rag TAG=v1.0.0 \
  HELM_EXTRA_ARGS='--set gpu.enabled=true \
                   --set gpu.nodeSelector.gpu=true \
                   --set gpu.tolerations[0].key=nvidia.com/gpu \
                   --set gpu.tolerations[0].operator=Exists \
                   --set gpu.tolerations[0].effect=NoSchedule'
```

## URL modes

Both modes driven by `.env`:

| Mode | `.env` | What the Makefile does |
|---|---|---|
| DNS / ingress | `BACKEND_URL = https://…` | Passes the URL via `--set backendUrl=`. Services stay at whatever your env YAML says. |
| NodePort fallback | `BACKEND_URL =` (empty) | Flips rest-api + monitoring to NodePort via `--set service.type=NodePort`, reads first node IP from `kubectl`, builds `http://<node-ip>:<REST_API_NODE_PORT>`. |

Same logic independently for `MONITORING_URL` / `MONITORING_NODE_PORT`.
Mixed is fine — supply one, leave the other empty.

## Prerequisites

- ECK operator (manages Elasticsearch + Kibana CRs)
- CFK operator (manages Kafka CR)
- A storage class matching `STORAGE_CLASS` in `.env`
- `kubectl` pointed at the target cluster
- GCR service account key JSON file (Arcanna images are private)

## Makefile reference

```
make init-env        Bootstrap envs/$ENV/ from envs/_template/ (skips if exists)
make reset-env       Delete envs/$ENV/ (interactive confirm) — loses customizations
make diff-env        Show drift between envs/$ENV/ and current template

make deploy-all      Full ordered deploy: init-env → infra → app → frontend
make upgrade-all     App services only (no infra, no secrets), with new tags
make deploy-<n>      Individual service (e.g. deploy-rest-api, deploy-worker)
make rollback-<n>    helm rollback a release
make status          Show releases, pods, PVCs
make check-secrets   Report which secrets exist in the namespace
```
