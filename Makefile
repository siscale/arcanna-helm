SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Configuration ────────────────────────────────────────────────────
ENV          ?= baremetal-stage
NAMESPACE    ?= arcanna
CHARTS_DIR   := charts
ENVS_DIR     := envs/$(ENV)
HELM_TIMEOUT := 300s

# Secret values — pass via env vars or --set in CI.
# NEVER hardcode these in the Makefile or values files.
POSTGRES_USER     ?=
POSTGRES_PASSWORD ?=
POSTGRES_DB       ?=
REDIS_PASSWORD    ?=
GCR_JSON_KEY_FILE ?=

# App secret values — auto-generated if empty
SEAL_TOKEN         ?= $(shell openssl rand -base64 24 2>/dev/null)
API_TOKEN          ?= $(shell openssl rand -base64 24 2>/dev/null)
RAG_API_KEY        ?= $(shell openssl rand -base64 24 2>/dev/null)
MONITORING_API_KEY ?= $(shell openssl rand -base64 24 2>/dev/null)
MONITORING_SECRET  ?= $(shell openssl rand -base64 24 2>/dev/null)

# Skip flags — set to true to skip pre-existing infra
SKIP_ES    ?= false
SKIP_KAFKA ?= false
SKIP_KB    ?= false

# ── Image tags ──────────────────────────────────────────────────────
# TAG sets the default for all app services. Override per-service if needed.
TAG                    ?= latest
REST_API_TAG           ?= $(TAG)
CORE_FRAMEWORK_TAG     ?= $(TAG)
MIGRATION_TAG          ?= $(TAG)
MODULAR_TAG            ?= $(TAG)
MONITORING_TAG         ?= $(TAG)

# ── Helpers ──────────────────────────────────────────────────────────
define helm_upgrade
	@echo "──── deploying $(1) [$(ENV)] ────"
	helm upgrade --install $(1) $(CHARTS_DIR)/$(1) \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/$(1)/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/$(1).yaml),-f $(ENVS_DIR)/$(1).yaml) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)
endef

# Deploy modular-service chart with per-service values file
define helm_modular
	@echo "──── deploying $(1) [$(ENV)] (modular-service) ────"
	helm upgrade --install $(1) $(CHARTS_DIR)/modular-service \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/modular-service/values.yaml \
		-f $(ENVS_DIR)/services/$(1).yaml \
		--set image.tag=$(2) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)
endef

define wait_for
	@echo "  ⏳ waiting for $(1)..."
	kubectl wait --for=condition=$(2) $(1) -n $(NAMESPACE) --timeout=$(HELM_TIMEOUT) 2>/dev/null || true
endef

# ── Namespace ───────────────────────────────────────────────────────
.PHONY: init-namespace
init-namespace:
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 \
		|| (echo "Creating namespace $(NAMESPACE)..." && kubectl create namespace $(NAMESPACE))
	@echo "✅ namespace $(NAMESPACE) ready"

# ── Secrets ─────────────────────────────────────────────────────────
.PHONY: create-secrets create-secret-postgres create-secret-redis create-secret-gcr check-secrets

create-secret-postgres: init-namespace
	@if kubectl get secret postgres-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  postgres-credentials already exists in $(NAMESPACE)"; \
	else \
		if [ -z "$(POSTGRES_USER)" ] || [ -z "$(POSTGRES_PASSWORD)" ] || [ -z "$(POSTGRES_DB)" ]; then \
			echo "❌ Missing env vars. Export POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB"; \
			exit 1; \
		fi; \
		echo "Creating postgres-credentials..."; \
		kubectl create secret generic postgres-credentials \
			-n $(NAMESPACE) \
			--from-literal=user="$(POSTGRES_USER)" \
			--from-literal=password="$(POSTGRES_PASSWORD)" \
			--from-literal=database="$(POSTGRES_DB)"; \
		echo "✅ postgres-credentials created"; \
	fi

create-secret-redis: init-namespace
	@if kubectl get secret redis-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  redis-credentials already exists in $(NAMESPACE)"; \
	else \
		if [ -z "$(REDIS_PASSWORD)" ]; then \
			echo "❌ Missing env var. Export REDIS_PASSWORD"; \
			exit 1; \
		fi; \
		echo "Creating redis-credentials..."; \
		kubectl create secret generic redis-credentials \
			-n $(NAMESPACE) \
			--from-literal=password="$(REDIS_PASSWORD)"; \
		echo "✅ redis-credentials created"; \
	fi

create-secret-gcr: init-namespace
	@if kubectl get secret gcr-pull-secret -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  gcr-pull-secret already exists in $(NAMESPACE)"; \
	else \
		if [ -z "$(GCR_JSON_KEY_FILE)" ] || [ ! -f "$(GCR_JSON_KEY_FILE)" ]; then \
			echo "❌ Set GCR_JSON_KEY_FILE to the path of the service account JSON"; \
			exit 1; \
		fi; \
		echo "Creating gcr-pull-secret..."; \
		kubectl create secret docker-registry gcr-pull-secret \
			-n $(NAMESPACE) \
			--docker-server=gcr.io \
			--docker-username=_json_key \
			--docker-password="$$(cat $(GCR_JSON_KEY_FILE))" \
			--docker-email=sa@arcanna.ai; \
		echo "✅ gcr-pull-secret created"; \
	fi

create-secret-app: init-namespace
	@if kubectl get secret arcanna-app-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  arcanna-app-credentials already exists in $(NAMESPACE)"; \
	else \
		echo "Creating arcanna-app-credentials (auto-generating tokens)..."; \
		kubectl create secret generic arcanna-app-credentials \
			-n $(NAMESPACE) \
			--from-literal=seal-token="$(SEAL_TOKEN)" \
			--from-literal=api-token="$(API_TOKEN)" \
			--from-literal=rag-api-key="$(RAG_API_KEY)" \
			--from-literal=monitoring-api-key="$(MONITORING_API_KEY)" \
			--from-literal=monitoring-secret="$(MONITORING_SECRET)"; \
		echo "✅ arcanna-app-credentials created"; \
		echo "   ⚠️  Save these values — they won't be shown again:"; \
		kubectl get secret arcanna-app-credentials -n $(NAMESPACE) -o json \
			| jq -r '.data | to_entries[] | "   \(.key): \(.value | @base64d)"'; \
	fi

create-secrets: create-secret-postgres create-secret-redis create-secret-gcr
	@echo ""
	@echo "══════ All infra secrets ready [$(NAMESPACE)] ══════"

check-secrets:
	@echo "Checking secrets in $(NAMESPACE):"
	@for s in postgres-credentials redis-credentials gcr-pull-secret arcanna-app-credentials; do \
		if kubectl get secret $$s -n $(NAMESPACE) >/dev/null 2>&1; then \
			echo "  ✅ $$s"; \
		else \
			echo "  ❌ $$s  (missing)"; \
		fi; \
	done
	@echo ""
	@echo "ECK-managed secrets (created after ES deploy):"
	@kubectl get secrets -n $(NAMESPACE) -o name 2>/dev/null | grep "elastic" | sed 's/^/  /' || echo "  (none yet — deploy elasticsearch first)"

# ── Infrastructure targets ───────────────────────────────────────────
.PHONY: deploy-elasticsearch deploy-kafka deploy-postgres deploy-redis deploy-kibana

deploy-elasticsearch: init-namespace
ifeq ($(SKIP_ES),true)
	@echo "⏭  skipping elasticsearch (SKIP_ES=true)"
else
	$(call helm_upgrade,elasticsearch)
	$(call wait_for,elasticsearch/$(shell yq '.clusterName' $(ENVS_DIR)/elasticsearch.yaml 2>/dev/null || echo aiops),ElasticsearchIsReady)
endif

deploy-kafka: init-namespace
ifeq ($(SKIP_KAFKA),true)
	@echo "⏭  skipping kafka (SKIP_KAFKA=true)"
else
	$(call helm_upgrade,kafka)
endif

deploy-postgres: init-namespace
	$(call helm_upgrade,postgres)
	$(call wait_for,deployment/$(NAMESPACE)-arcanna-postgres,Available)

deploy-redis: init-namespace
	$(call helm_upgrade,redis)
	$(call wait_for,deployment/$(NAMESPACE)-arcanna-redis,Available)

deploy-kibana:
ifeq ($(SKIP_KB),true)
	@echo "⏭  skipping kibana (SKIP_KB=true)"
else
	$(MAKE) deploy-elasticsearch ENV=$(ENV) NAMESPACE=$(NAMESPACE) SKIP_ES=$(SKIP_ES)
	$(call helm_upgrade,kibana)
endif

# ── Adopt pre-existing resources into Helm ───────────────────────────
# One-time operation for resources created before Helm migration.
# After adoption, Helm manages the resource lifecycle normally.
.PHONY: adopt-existing
adopt-existing:
	@echo "Adopting pre-existing CRs into Helm releases in $(NAMESPACE)..."
	@ES_NAME=$$(yq '.clusterName' $(ENVS_DIR)/elasticsearch.yaml 2>/dev/null || echo "aiops"); \
	KB_NAME=$$(yq '.name' $(ENVS_DIR)/kibana.yaml 2>/dev/null || echo "aiops"); \
	echo ""; \
	echo "── Elasticsearch: $$ES_NAME ──"; \
	if kubectl get elasticsearch $$ES_NAME -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl -n $(NAMESPACE) label elasticsearch $$ES_NAME \
			app.kubernetes.io/managed-by=Helm --overwrite; \
		kubectl -n $(NAMESPACE) annotate elasticsearch $$ES_NAME \
			meta.helm.sh/release-name=elasticsearch \
			meta.helm.sh/release-namespace=$(NAMESPACE) --overwrite; \
		echo "  ✅ adopted"; \
	else \
		echo "  ⏭  not found, skipping"; \
	fi; \
	echo ""; \
	echo "── Kibana: $$KB_NAME ──"; \
	if kubectl get kibana $$KB_NAME -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl -n $(NAMESPACE) label kibana $$KB_NAME \
			app.kubernetes.io/managed-by=Helm --overwrite; \
		kubectl -n $(NAMESPACE) annotate kibana $$KB_NAME \
			meta.helm.sh/release-name=kibana \
			meta.helm.sh/release-namespace=$(NAMESPACE) --overwrite; \
		echo "  ✅ adopted"; \
	else \
		echo "  ⏭  not found, skipping"; \
	fi; \
	echo ""; \
	echo "── KRaftController: kraftcontroller ──"; \
	if kubectl get kraftcontroller kraftcontroller -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl -n $(NAMESPACE) label kraftcontroller kraftcontroller \
			app.kubernetes.io/managed-by=Helm --overwrite; \
		kubectl -n $(NAMESPACE) annotate kraftcontroller kraftcontroller \
			meta.helm.sh/release-name=kafka \
			meta.helm.sh/release-namespace=$(NAMESPACE) --overwrite; \
		echo "  ✅ adopted"; \
	else \
		echo "  ⏭  not found, skipping"; \
	fi; \
	echo ""; \
	echo "── Kafka: kafka ──"; \
	if kubectl get kafka kafka -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl -n $(NAMESPACE) label kafka kafka \
			app.kubernetes.io/managed-by=Helm --overwrite; \
		kubectl -n $(NAMESPACE) annotate kafka kafka \
			meta.helm.sh/release-name=kafka \
			meta.helm.sh/release-namespace=$(NAMESPACE) --overwrite; \
		echo "  ✅ adopted"; \
	else \
		echo "  ⏭  not found, skipping"; \
	fi; \
	echo ""; \
	echo "══════ adoption complete — now run deploy-infra ══════"

# ── Grouped infra target ────────────────────────────────────────────
.PHONY: deploy-infra
deploy-infra: init-namespace create-secrets deploy-elasticsearch deploy-kafka deploy-postgres deploy-redis deploy-kibana
	@echo "══════ infra deployed [$(ENV)] ══════"

# ── Application targets ─────────────────────────────────────────────
.PHONY: deploy-migration-start deploy-migration-end deploy-rest-api deploy-core-framework deploy-hypervisor deploy-exposer
.PHONY: deploy-agents-exposer deploy-arcanna-rag deploy-mcp-client
.PHONY: deploy-workers deploy-monitoring deploy-platform

# Migration helper — Jobs are immutable, so uninstall old release before installing new
define helm_migration
	@echo "──── migration $(1) [$(ENV)] ────"
	-helm uninstall migration-$(1) -n $(NAMESPACE) 2>/dev/null
	@sleep 2
	helm install migration-$(1) $(CHARTS_DIR)/migration \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/migration/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/migration.yaml),-f $(ENVS_DIR)/migration.yaml) \
		--set phase=$(1) \
		--set extraArgs=$(2) \
		$(HELM_EXTRA_ARGS)
	@echo "  ⏳ waiting for migration-$(1)..."
	kubectl wait --for=condition=complete job/migration-$(1) \
		-n $(NAMESPACE) --timeout=1200s
endef

deploy-migration-start:
	$(call helm_migration,start,--stop-jobs)

deploy-migration-end:
	$(call helm_migration,end,--start-jobs)

deploy-rest-api:
	@if kubectl get secret arcanna-app-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "──── deploying aiops-rest-api [$(ENV)] (secret exists, skipping creation) ────"; \
		helm upgrade --install aiops-rest-api $(CHARTS_DIR)/aiops-rest-api \
			-n $(NAMESPACE) \
			-f $(CHARTS_DIR)/aiops-rest-api/values.yaml \
			$(if $(wildcard $(ENVS_DIR)/aiops-rest-api.yaml),-f $(ENVS_DIR)/aiops-rest-api.yaml) \
			--set secrets.create=false \
			--timeout $(HELM_TIMEOUT) \
			--wait \
			$(HELM_EXTRA_ARGS); \
	else \
		echo "──── deploying aiops-rest-api [$(ENV)] (generating app secrets) ────"; \
		helm upgrade --install aiops-rest-api $(CHARTS_DIR)/aiops-rest-api \
			-n $(NAMESPACE) \
			-f $(CHARTS_DIR)/aiops-rest-api/values.yaml \
			$(if $(wildcard $(ENVS_DIR)/aiops-rest-api.yaml),-f $(ENVS_DIR)/aiops-rest-api.yaml) \
			--set secrets.create=true \
			--set secrets.sealToken="$(SEAL_TOKEN)" \
			--set secrets.apiToken="$(API_TOKEN)" \
			--set secrets.ragApiKey="$(RAG_API_KEY)" \
			--set secrets.monitoringApiKey="$(MONITORING_API_KEY)" \
			--set secrets.monitoringSecret="$(MONITORING_SECRET)" \
			--timeout $(HELM_TIMEOUT) \
			--wait \
			$(HELM_EXTRA_ARGS); \
		echo "  ✅ arcanna-app-credentials created with auto-generated tokens"; \
		echo "  ⚠️  Save these values:"; \
		kubectl get secret arcanna-app-credentials -n $(NAMESPACE) -o json \
			| jq -r '.data | to_entries[] | "     \(.key): \(.value | @base64d)"' 2>/dev/null || true; \
	fi

deploy-core-framework:
	$(call helm_upgrade,core-framework)

# ── Modular-service deployments (one chart, per-service values) ──────
.PHONY: deploy-hypervisor deploy-exposer deploy-agents-exposer
.PHONY: deploy-cacher deploy-clustering deploy-buckets-updater deploy-retrainer
.PHONY: deploy-worker deploy-feedbacker deploy-remote-llm deploy-monitoring

deploy-hypervisor:
	$(call helm_modular,hypervisor,$(MODULAR_TAG))

deploy-exposer:
	$(call helm_modular,exposer,$(MODULAR_TAG))

deploy-agents-exposer:
	$(call helm_modular,agents-exposer,$(MODULAR_TAG))

deploy-cacher:
	$(call helm_modular,cacher,$(MODULAR_TAG))

deploy-clustering:
	$(call helm_modular,clustering,$(MODULAR_TAG))

deploy-buckets-updater:
	$(call helm_modular,buckets-updater,$(MODULAR_TAG))

deploy-retrainer:
	$(call helm_modular,retrainer,$(MODULAR_TAG))

deploy-worker:
	$(call helm_modular,worker,$(MODULAR_TAG))

deploy-feedbacker:
	$(call helm_modular,feedbacker,$(MODULAR_TAG))

deploy-remote-llm:
	$(call helm_modular,remote-llm,$(MODULAR_TAG))

deploy-monitoring:
	@echo "──── deploying monitoring [$(ENV)] ────"
	helm upgrade --install monitoring $(CHARTS_DIR)/monitoring \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/monitoring/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/services/monitoring.yaml),-f $(ENVS_DIR)/services/monitoring.yaml) \
		--set image.tag=$(MONITORING_TAG) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-arcanna-rag:
	$(call helm_upgrade,arcanna-rag)

deploy-mcp-client:
	$(call helm_upgrade,mcp-client)

deploy-platform:
	$(call helm_upgrade,aiops-platform)

deploy-main-config:
	$(call helm_upgrade,main-config)

# ── Full deploy (secrets → infra → app, ordered) ────────────────────
.PHONY: deploy-all
deploy-all: deploy-infra
	@echo ""
	@echo "══════ Phase 2: shared config ══════"
	$(MAKE) deploy-main-config ENV=$(ENV)
	@echo ""
	@echo "══════ Phase 3: migration start (stop jobs) ══════"
	$(MAKE) deploy-migration-start ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(MIGRATION_TAG)'
	@echo ""
	@echo "══════ Phase 4: core services ══════"
	$(MAKE) deploy-rest-api ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(REST_API_TAG)'
	$(MAKE) deploy-core-framework ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(CORE_FRAMEWORK_TAG)'
	$(MAKE) deploy-hypervisor ENV=$(ENV)
	$(MAKE) deploy-exposer ENV=$(ENV)
	$(MAKE) deploy-agents-exposer ENV=$(ENV)
	$(MAKE) deploy-feedbacker ENV=$(ENV)
	$(MAKE) deploy-remote-llm ENV=$(ENV)
	@echo ""
	@echo "══════ Phase 5: workers + processing ══════"
	$(MAKE) deploy-worker ENV=$(ENV)
	$(MAKE) deploy-buckets-updater ENV=$(ENV)
	$(MAKE) deploy-retrainer ENV=$(ENV)
	$(MAKE) deploy-clustering ENV=$(ENV)
	$(MAKE) deploy-cacher ENV=$(ENV)
	@echo ""
	@echo "══════ Phase 6: monitoring ══════"
	$(MAKE) deploy-monitoring ENV=$(ENV)
	@echo ""
	@echo "══════ Phase 7: migration end (start jobs) ══════"
	$(MAKE) deploy-migration-end ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(MIGRATION_TAG)'
	@echo ""
	@echo "══════ Phase 8: frontend ══════"
	$(MAKE) deploy-platform ENV=$(ENV)
	@echo ""
	@echo "✅ Full deploy complete [$(ENV)]"

# ── Upgrade shortcut (app services only, no infra) ──────────────────
.PHONY: upgrade-all
upgrade-all:
	@echo "══════ Upgrading app services [$(ENV)] TAG=$(TAG) ══════"
	@echo ""
	$(MAKE) deploy-main-config ENV=$(ENV)
	$(MAKE) deploy-migration-start ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(MIGRATION_TAG)'
	$(MAKE) deploy-rest-api ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(REST_API_TAG)'
	$(MAKE) deploy-core-framework ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(CORE_FRAMEWORK_TAG)'
	$(MAKE) deploy-hypervisor ENV=$(ENV)
	$(MAKE) deploy-exposer ENV=$(ENV)
	$(MAKE) deploy-agents-exposer ENV=$(ENV)
	$(MAKE) deploy-feedbacker ENV=$(ENV)
	$(MAKE) deploy-remote-llm ENV=$(ENV)
	$(MAKE) deploy-worker ENV=$(ENV)
	$(MAKE) deploy-buckets-updater ENV=$(ENV)
	$(MAKE) deploy-retrainer ENV=$(ENV)
	$(MAKE) deploy-clustering ENV=$(ENV)
	$(MAKE) deploy-cacher ENV=$(ENV)
	$(MAKE) deploy-monitoring ENV=$(ENV)
	$(MAKE) deploy-migration-end ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(MIGRATION_TAG)'
	@echo ""
	@echo "✅ Upgrade complete [$(ENV)] TAG=$(TAG)"

# ── Rollback ────────────────────────────────────────────────────────
.PHONY: rollback-%
rollback-%:
	@echo "Rolling back $*..."
	helm rollback $* -n $(NAMESPACE) 0

# ── Status / Debug ──────────────────────────────────────────────────
.PHONY: status
status:
	@echo "Helm releases in $(NAMESPACE):"
	@helm list -n $(NAMESPACE) -o table
	@echo ""
	@echo "Pods:"
	@kubectl get pods -n $(NAMESPACE) --sort-by=.metadata.name
	@echo ""
	@echo "PVCs:"
	@kubectl get pvc -n $(NAMESPACE)

# ── Teardown (careful!) ─────────────────────────────────────────────
.PHONY: destroy-infra
destroy-infra:
	@echo "⚠️  This will DELETE all infra releases in $(NAMESPACE). Ctrl+C to abort."
	@sleep 5
	-helm uninstall kibana        -n $(NAMESPACE) 2>/dev/null
	-helm uninstall kafka         -n $(NAMESPACE) 2>/dev/null
	-helm uninstall redis         -n $(NAMESPACE) 2>/dev/null
	-helm uninstall postgres      -n $(NAMESPACE) 2>/dev/null
	-helm uninstall elasticsearch -n $(NAMESPACE) 2>/dev/null
	@echo "Infra releases removed. PVCs and secrets are retained."

# ── Help ────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Arcanna Infrastructure + Platform Deploy"
	@echo ""
	@echo "Usage: make <target> ENV=<environment> NAMESPACE=<ns>"
	@echo ""
	@echo "Environments:"
	@ls -1 envs/ 2>/dev/null || echo "  (none found)"
	@echo ""
	@echo "Secrets (run first):"
	@echo "  create-secrets        Create all secrets (postgres, redis, gcr)"
	@echo "  create-secret-postgres"
	@echo "  create-secret-redis"
	@echo "  create-secret-gcr"
	@echo "  check-secrets         Verify secrets exist"
	@echo ""
	@echo "Infrastructure:"
	@echo "  deploy-infra          Secrets + all infra (ES, Kafka, PG, Redis, Kibana)"
	@echo "  deploy-elasticsearch  Deploy Elasticsearch via ECK"
	@echo "  deploy-kafka          Deploy Kafka + KRaft via CFK"
	@echo "  deploy-postgres       Deploy PostgreSQL"
	@echo "  deploy-redis          Deploy Redis"
	@echo "  deploy-kibana         Deploy Kibana via ECK"
	@echo "  adopt-existing        Adopt pre-Helm CRs (ES, Kibana, Kafka) into Helm"
	@echo ""
	@echo "  Skip flags: SKIP_ES=true SKIP_KAFKA=true SKIP_KB=true"
	@echo ""
	@echo "Application:"
	@echo "  deploy-rest-api       Deploy Flask REST API"
	@echo "  deploy-core-framework Deploy core-framework"
	@echo "  deploy-mcp-client     Deploy MCP client"
	@echo "  deploy-arcanna-rag    Deploy RAG pipeline"
	@echo "  deploy-workers        Deploy workers (HPA)"
	@echo "  deploy-platform       Deploy React frontend"
	@echo "  deploy-migration-start Run ES migration (--stop-jobs)"
	@echo "  deploy-migration-end   Run ES migration (--start-jobs)"
	@echo ""
	@echo "Lifecycle:"
	@echo "  deploy-all            Full ordered deploy (secrets + infra + app)"
	@echo "  upgrade-all           App services only (no infra, no secrets)"
	@echo "  rollback-<n>       Rollback a Helm release"
	@echo "  status                Show releases, pods, PVCs"
	@echo "  destroy-infra         Remove infra releases (keeps PVCs/secrets)"
	@echo ""
	@echo "Image tags:"
	@echo "  TAG=<sha>               Default tag for all services"
	@echo "  REST_API_TAG=<sha>      Override rest-api only"
	@echo "  CORE_FRAMEWORK_TAG=<sha>"
	@echo "  MIGRATION_TAG=<sha>"
	@echo ""
	@echo "Examples:"
	@echo "  # Fresh cluster"
	@echo "  export POSTGRES_USER=arcanna POSTGRES_PASSWORD=s3cret POSTGRES_DB=arcanna"
	@echo "  export REDIS_PASSWORD=r3dis GCR_JSON_KEY_FILE=~/sa-key.json"
	@echo "  make deploy-all ENV=baremetal-stage NAMESPACE=arcanna-stage TAG=abc123"
	@echo ""
	@echo "  # Upgrade all services (same tag)"
	@echo "  make upgrade-all ENV=baremetal-stage NAMESPACE=arcanna-stage TAG=def456"
	@echo ""
	@echo "  # Upgrade with per-service tags"
	@echo "  make upgrade-all ENV=baremetal-stage NAMESPACE=arcanna-stage REST_API_TAG=v1.79.0 CORE_FRAMEWORK_TAG=abc123"
	@echo ""
	@echo "  # Single service"
	@echo "  make deploy-rest-api ENV=baremetal-stage NAMESPACE=arcanna-stage HELM_EXTRA_ARGS='--set image.tag=v1.79.0'"
