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

# 6  Deploy aiops-mcp client
```
make deploy-mcp-client ENV=baremetal-stage NAMESPACE=arcanna-stage TAG=b7b21686917ede432ceafda01d959f8b4d173e12
```


# 7 . Deploy arcanna-rag (optional)

```
make deploy-arcanna-rag ENV=baremetal-stage NAMESPACE=arcanna-stage   TAG=c2dd2d389c7924ad12eace9cb6d0e3b03d34260e
```

Using a node selector using KUBERNETES taints


```
make deploy-arcanna-rag ENV=baremetal-stage NAMESPACE=arcanna-stage   TAG=your-rag-image-tag \
  HELM_EXTRA_ARGS='--set gpu.enabled=true --set gpu.nodeSelector.gpu=true --set gpu.tolerations[0].key=nvidia.com/gpu --set gpu.tolerations[0].operator=Exists --set gpu.tolerations[0].effect=NoSchedule'
```

A tolerations is the oppossite of  node selector.GPU nodes typically have a taint that says "don't schedule anything here unless you explicitly tolerate this"
```
kubectl taint node k8s-worker nvidia.com/gpu=:NoSchedule
```

#8. Deploy aiops-platform.
```
 make deploy-platform ENV=baremetal-stage NAMESPACE=arcanna-stage PLATFORM_TAG=73a40ca70abd650e92e768944626950d5605e62b

```



#10. Upgrade all

```
make upgrade-all ENV=baremetal-stage NAMESPACE=arcanna-stage \
  REST_API_TAG=v1.78.1 \
  CORE_FRAMEWORK_TAG=v1.78.1 \
  MIGRATION_TAG=v1.78.1 \
  MODULAR_TAG=v1.78.1 \
  MONITORING_TAG=v1.78.1 \
  MCP_CLIENT_TAG=v1.7.3 \
  PLATFORM_TAG=v1.78.0
  
  
  
make deploy-arcanna-rag ENV=baremetal-stage NAMESPACE=arcanna-stage TAG=v1.0.0
```


