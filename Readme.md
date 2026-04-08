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