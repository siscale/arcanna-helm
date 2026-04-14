### deploy all


# Prerequisites: ECK operator + CFK operator already installed
# kubectl context pointing at the right cluster

cd arcanna-infra

# 1. Export secrets (one time — these never go in git)
```
export POSTGRES_USER=arcanna
export POSTGRES_PASSWORD=$(openssl rand -base64 24)
export POSTGRES_DB=arcanna
export REDIS_PASSWORD=$(openssl rand -base64 24)
export GCR_JSON_KEY_FILE=~/keys/gcr-sa.json
```
ex :
POSTGRES_PASSWORD=fclSSEzA1vmVXjx6PhnYaEEEyvdp7cFQ
REDIS_PASSWORD=57dB/Fb16SUko2OBg3hxHz1jA9TeLtrY

# 2. Deploy everything (namespace → secrets → infra → app)
```
make deploy-all ENV=baremetal-stage NAMESPACE=arcanna-stage
```


# 3. — Individual component (redeploy or debug):
```
bash# Just postgres
make deploy-postgres ENV=baremetal-stage NAMESPACE=arcanna-stage
```
# Just redis with a version override
```
make deploy-redis ENV=baremetal-stage NAMESPACE=arcanna-stage \
  HELM_EXTRA_ARGS='--set image.tag=7.2-alpine'
```
# Just kafka
```
make deploy-kafka ENV=baremetal-stage NAMESPACE=arcanna-stage
```


# Alternatively with helm

```
helm upgrade --install postgres charts/postgres \
  -n arcanna-stage \
  -f charts/postgres/values.yaml \
  -f envs/baremetal-stage/postgres.yaml \
  --set secret.create=true \
  --set secret.user="$POSTGRES_USER" \
  --set secret.password="$POSTGRES_PASSWORD" \
  --set secret.database="$POSTGRES_DB"
```




# 4. Deploy rest-api + samples
```
make deploy-rest-api ENV=baremetal-stage NAMESPACE=arcanna-stage HELM_EXTRA_ARGS='--set image.tag=584dc12c5b5b630653c28448807d1acc9309966f'
```
 # 5. Deploy services form modular

```
# Config (once)
make deploy-main-config ENV=baremetal-stage NAMESPACE=arcanna-stage

# All modular services (MODULAR_TAG)
make deploy-hypervisor ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-exposer ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-agents-exposer ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-cacher ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-clustering ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-buckets-updater ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-retrainer ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-worker ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
make deploy-remote-llm ENV=baremetal-stage NAMESPACE=arcanna-stage MODULAR_TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8

# Monitoring (uses MONITORING_TAG or TAG, not MODULAR_TAG)
make deploy-monitoring ENV=baremetal-stage NAMESPACE=arcanna-stage TAG=fe66d88bf12918d6a2c9b86d1034df811d2dc8d8
# end migration

make deploy-migration-end ENV=baremetal-stage NAMESPACE=arcanna-stage \
  HELM_EXTRA_ARGS='--set image.tag=8cea2247d73c89d67ecaa3d01bb3a310f8133044
```
