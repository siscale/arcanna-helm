SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Per-installation config ──────────────────────────────────────────
# Loaded from .env at repo root. Copy .env.example to .env and edit.
# The file is optional — unset keys fall through to the defaults below.
-include .env
export

# ── Configuration ────────────────────────────────────────────────────
ENV          ?= baremetal-stage
NAMESPACE    ?= arcanna
CHARTS_DIR   := charts
ENVS_DIR     := envs/$(ENV)
HELM_TIMEOUT         := 300s
HELM_SPECIAL_TIMEOUT := 600s

# NodePorts used when BACKEND_URL / MONITORING_URL are empty.
REST_API_NODE_PORT   ?= 31301
MONITORING_NODE_PORT ?= 31302

# Env bootstrap defaults (used by `make init-env` when .env doesn't set them).
ES_CLUSTER_NAME    ?= aiops-$(ENV)
STORAGE_CLASS      ?= sc-default
PLATFORM_NODE_PORT ?= 31400
EXPOSER_NODE_PORT  ?= 31403

# When URLs are empty, services must expose NodePorts for the
# auto-resolved URLs (http://<node-ip>:<port>) to actually work.
# These --set flags are merged onto the rest-api / monitoring helm calls.
REST_API_NODEPORT_ARGS   = $(if $(BACKEND_URL),,--set service.type=NodePort --set service.nodePort.enabled=true --set service.nodePort.port=$(REST_API_NODE_PORT))
MONITORING_NODEPORT_ARGS = $(if $(MONITORING_URL),,--set service.type=NodePort --set service.nodePort.enabled=true --set service.nodePort.port=$(MONITORING_NODE_PORT))

# Infra secrets.
# Left empty here on purpose — the create-secret-* targets auto-generate
# sensible values on first deploy and persist them in Kubernetes secrets.
# Override via env vars only if you want specific credentials.
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
PLATFORM_TAG           ?= $(TAG)
MCP_CLIENT_TAG         ?= $(TAG)
RELEASE_VERSION        ?= $(TAG)

# ── Helpers ──────────────────────────────────────────────────────────
define helm_upgrade
	@echo "──── deploying $(1) [$(ENV)] ────"
	helm upgrade --install $(1) $(CHARTS_DIR)/$(1) \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/$(1)/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
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
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
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

# ── Env bootstrap ───────────────────────────────────────────────────
# `init-env` creates envs/$(ENV)/ from envs/_template/, substituting
# values from .env. Idempotent: skips if envs/$(ENV)/ already exists.
# Auto-called by deploy-all — fresh clones work with no manual setup.
.PHONY: init-env reset-env diff-env

init-env:
	@if [ -z "$(ENV)" ]; then echo "❌ ENV=<name> required"; exit 1; fi
	@if [ -d "$(ENVS_DIR)" ]; then \
		echo "⏭  envs/$(ENV) already exists — keeping your customizations"; \
	else \
		echo "──── bootstrapping envs/$(ENV) from template ────"; \
		echo "  ENV_NAME           = $(ENV)"; \
		echo "  ES_CLUSTER_NAME    = $(ES_CLUSTER_NAME)"; \
		echo "  STORAGE_CLASS      = $(STORAGE_CLASS)"; \
		echo "  PLATFORM_NODE_PORT = $(PLATFORM_NODE_PORT)"; \
		echo "  EXPOSER_NODE_PORT  = $(EXPOSER_NODE_PORT)"; \
		mkdir -p $(ENVS_DIR)/services; \
		for f in envs/_template/*.yaml envs/_template/services/*.yaml; do \
			rel=$${f#envs/_template/}; \
			dest=$(ENVS_DIR)/$$rel; \
			mkdir -p $$(dirname $$dest); \
			sed -e "s|@ENV_NAME@|$(ENV)|g" \
			    -e "s|@ES_CLUSTER_NAME@|$(ES_CLUSTER_NAME)|g" \
			    -e "s|@STORAGE_CLASS@|$(STORAGE_CLASS)|g" \
			    -e "s|@PLATFORM_NODE_PORT@|$(PLATFORM_NODE_PORT)|g" \
			    -e "s|@EXPOSER_NODE_PORT@|$(EXPOSER_NODE_PORT)|g" \
			    "$$f" > "$$dest"; \
		done; \
		echo "✅ envs/$(ENV) created ($$(find $(ENVS_DIR) -type f | wc -l) files)"; \
		echo "   Review/edit the files above if needed, then run: make deploy-all"; \
	fi

reset-env:
	@if [ -z "$(ENV)" ]; then echo "❌ ENV=<name> required"; exit 1; fi
	@if [ ! -d "$(ENVS_DIR)" ]; then echo "⏭  envs/$(ENV) doesn't exist"; exit 0; fi
	@echo "⚠️  This will DELETE envs/$(ENV)/ — your local customizations will be lost."
	@read -p "   Type the env name to confirm: " confirm && [ "$$confirm" = "$(ENV)" ] || { echo "cancelled"; exit 1; }
	rm -rf "$(ENVS_DIR)"
	@echo "✅ envs/$(ENV) removed. Run `make init-env ENV=$(ENV)` to regenerate."

diff-env:
	@if [ -z "$(ENV)" ]; then echo "❌ ENV=<name> required"; exit 1; fi
	@if [ ! -d "$(ENVS_DIR)" ]; then echo "❌ envs/$(ENV) doesn't exist — run init-env first"; exit 1; fi
	@echo "── drift between envs/$(ENV)/ and current envs/_template/ ──"
	@echo "(shows what your env has that the template doesn't, and vice versa)"
	@TMP=$$(mktemp -d); \
	for f in envs/_template/*.yaml envs/_template/services/*.yaml; do \
		rel=$${f#envs/_template/}; \
		mkdir -p $$TMP/$$(dirname $$rel); \
		sed -e "s|@ENV_NAME@|$(ENV)|g" \
		    -e "s|@ES_CLUSTER_NAME@|$(ES_CLUSTER_NAME)|g" \
		    -e "s|@STORAGE_CLASS@|$(STORAGE_CLASS)|g" \
		    -e "s|@PLATFORM_NODE_PORT@|$(PLATFORM_NODE_PORT)|g" \
		    -e "s|@EXPOSER_NODE_PORT@|$(EXPOSER_NODE_PORT)|g" \
		    "$$f" > "$$TMP/$$rel"; \
	done; \
	diff -ruN $$TMP $(ENVS_DIR) || true; \
	rm -rf $$TMP

# ── Secrets ─────────────────────────────────────────────────────────
.PHONY: create-secrets create-secret-postgres create-secret-redis create-secret-gcr check-secrets

create-secret-postgres: init-namespace
	@if kubectl get secret postgres-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  postgres-credentials already exists in $(NAMESPACE)"; \
	else \
		USER="$${POSTGRES_USER:-$(POSTGRES_USER)}"; USER="$${USER:-arcanna}"; \
		DB="$${POSTGRES_DB:-$(POSTGRES_DB)}"; DB="$${DB:-arcanna}"; \
		PASS="$${POSTGRES_PASSWORD:-$(POSTGRES_PASSWORD)}"; \
		if [ -z "$$PASS" ]; then \
			PASS=$$(openssl rand -base64 32 | tr -d '/+=' | head -c 32); \
			GENERATED=1; \
		fi; \
		echo "Creating postgres-credentials..."; \
		kubectl create secret generic postgres-credentials \
			-n $(NAMESPACE) \
			--from-literal=user="$$USER" \
			--from-literal=password="$$PASS" \
			--from-literal=database="$$DB"; \
		echo "✅ postgres-credentials created"; \
		if [ -n "$$GENERATED" ]; then \
			echo "   ⚠️  Auto-generated password — save it now, it won't be shown again:"; \
			echo "     user:     $$USER"; \
			echo "     password: $$PASS"; \
			echo "     database: $$DB"; \
		fi; \
	fi

create-secret-redis: init-namespace
	@if kubectl get secret redis-credentials -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "⏭  redis-credentials already exists in $(NAMESPACE)"; \
	else \
		PASS="$${REDIS_PASSWORD:-$(REDIS_PASSWORD)}"; \
		if [ -z "$$PASS" ]; then \
			PASS=$$(openssl rand -base64 32 | tr -d '/+=' | head -c 32); \
			GENERATED=1; \
		fi; \
		echo "Creating redis-credentials..."; \
		kubectl create secret generic redis-credentials \
			-n $(NAMESPACE) \
			--from-literal=password="$$PASS"; \
		echo "✅ redis-credentials created"; \
		if [ -n "$$GENERATED" ]; then \
			echo "   ⚠️  Auto-generated password — save it now, it won't be shown again:"; \
			echo "     password: $$PASS"; \
		fi; \
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
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
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
		echo "──── deploying aiops-rest-api [$(ENV)] tag=$(REST_API_TAG) (secret exists) ────"; \
		helm upgrade --install aiops-rest-api $(CHARTS_DIR)/aiops-rest-api \
			-n $(NAMESPACE) \
			-f $(CHARTS_DIR)/aiops-rest-api/values.yaml \
			$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
			$(if $(wildcard $(ENVS_DIR)/aiops-rest-api.yaml),-f $(ENVS_DIR)/aiops-rest-api.yaml) \
			--set image.tag=$(REST_API_TAG) \
			--set secrets.create=false \
			--set config.releaseVersion="$(RELEASE_VERSION)" \
			$(REST_API_NODEPORT_ARGS) \
			--timeout $(HELM_TIMEOUT) \
			--wait \
			$(HELM_EXTRA_ARGS); \
	else \
		echo "──── deploying aiops-rest-api [$(ENV)] tag=$(REST_API_TAG) (generating app secrets) ────"; \
		helm upgrade --install aiops-rest-api $(CHARTS_DIR)/aiops-rest-api \
			-n $(NAMESPACE) \
			-f $(CHARTS_DIR)/aiops-rest-api/values.yaml \
			$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
			$(if $(wildcard $(ENVS_DIR)/aiops-rest-api.yaml),-f $(ENVS_DIR)/aiops-rest-api.yaml) \
			--set image.tag=$(REST_API_TAG) \
			--set secrets.create=true \
			--set config.releaseVersion="$(RELEASE_VERSION)" \
			--set secrets.sealToken="$(SEAL_TOKEN)" \
			--set secrets.apiToken="$(API_TOKEN)" \
			--set secrets.ragApiKey="$(RAG_API_KEY)" \
			--set secrets.monitoringApiKey="$(MONITORING_API_KEY)" \
			--set secrets.monitoringSecret="$(MONITORING_SECRET)" \
			$(REST_API_NODEPORT_ARGS) \
			--timeout $(HELM_TIMEOUT) \
			--wait \
			$(HELM_EXTRA_ARGS); \
		echo "  ✅ arcanna-app-credentials created with auto-generated tokens"; \
		echo "  ⚠️  Save these values:"; \
		kubectl get secret arcanna-app-credentials -n $(NAMESPACE) -o json \
			| jq -r '.data | to_entries[] | "     \(.key): \(.value | @base64d)"' 2>/dev/null || true; \
	fi

deploy-core-framework:
	@echo "──── deploying core-framework [$(ENV)] tag=$(CORE_FRAMEWORK_TAG) ────"
	helm upgrade --install core-framework $(CHARTS_DIR)/core-framework \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/core-framework/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		$(if $(wildcard $(ENVS_DIR)/core-framework.yaml),-f $(ENVS_DIR)/core-framework.yaml) \
		--set image.tag=$(CORE_FRAMEWORK_TAG) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

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
	@echo "──── deploying worker [$(ENV)] (modular-service) ────"
	helm upgrade --install worker $(CHARTS_DIR)/modular-service \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/modular-service/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		-f $(ENVS_DIR)/services/worker.yaml \
		--set image.tag=$(MODULAR_TAG) \
		--timeout $(HELM_SPECIAL_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-feedbacker:
	$(call helm_modular,feedbacker,$(MODULAR_TAG))

deploy-remote-llm:
	$(call helm_modular,remote-llm,$(MODULAR_TAG))

deploy-monitoring:
	@echo "──── deploying monitoring [$(ENV)] ────"
	helm upgrade --install monitoring $(CHARTS_DIR)/monitoring \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/monitoring/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		$(if $(wildcard $(ENVS_DIR)/services/monitoring.yaml),-f $(ENVS_DIR)/services/monitoring.yaml) \
		--set image.tag=$(MONITORING_TAG) \
		$(MONITORING_NODEPORT_ARGS) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-arcanna-rag:
	@echo "──── deploying arcanna-rag [$(ENV)] (manual — not in deploy-all) ────"
	helm upgrade --install arcanna-rag $(CHARTS_DIR)/arcanna-rag \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/arcanna-rag/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		$(if $(wildcard $(ENVS_DIR)/arcanna-rag.yaml),-f $(ENVS_DIR)/arcanna-rag.yaml) \
		--set image.tag=$(TAG) \
		--timeout $(HELM_SPECIAL_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-mcp-client:
	@echo "──── deploying aiops-mcp-client [$(ENV)] ────"
	helm upgrade --install aiops-mcp-client $(CHARTS_DIR)/aiops-mcp-client \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/aiops-mcp-client/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		$(if $(wildcard $(ENVS_DIR)/aiops-mcp-client.yaml),-f $(ENVS_DIR)/aiops-mcp-client.yaml) \
		--set image.tag=$(MCP_CLIENT_TAG) \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-platform:
	@echo "──── deploying aiops-platform [$(ENV)] ────"
	@BURL="$${BACKEND_URL:-$(BACKEND_URL)}"; \
	MURL="$${MONITORING_URL:-$(MONITORING_URL)}"; \
	if [ -z "$$BURL" ] || [ -z "$$MURL" ]; then \
		NODE_IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); \
		if [ -z "$$NODE_IP" ]; then \
			echo "❌ BACKEND_URL/MONITORING_URL are empty and no node IP could be detected."; \
			echo "   Either set the URLs in .env, or ensure kubectl can reach the cluster."; \
			exit 1; \
		fi; \
		if [ -z "$$BURL" ]; then \
			BURL="http://$$NODE_IP:$(REST_API_NODE_PORT)"; \
			echo "  ℹ  BACKEND_URL    = $$BURL  (auto: node IP + REST_API_NODE_PORT)"; \
		else \
			echo "  ℹ  BACKEND_URL    = $$BURL  (from .env)"; \
		fi; \
		if [ -z "$$MURL" ]; then \
			MURL="http://$$NODE_IP:$(MONITORING_NODE_PORT)"; \
			echo "  ℹ  MONITORING_URL = $$MURL  (auto: node IP + MONITORING_NODE_PORT)"; \
		else \
			echo "  ℹ  MONITORING_URL = $$MURL  (from .env)"; \
		fi; \
	else \
		echo "  ℹ  BACKEND_URL    = $$BURL  (from .env)"; \
		echo "  ℹ  MONITORING_URL = $$MURL  (from .env)"; \
	fi; \
	helm upgrade --install aiops-platform $(CHARTS_DIR)/aiops-platform \
		-n $(NAMESPACE) \
		-f $(CHARTS_DIR)/aiops-platform/values.yaml \
		$(if $(wildcard $(ENVS_DIR)/_common.yaml),-f $(ENVS_DIR)/_common.yaml) \
		$(if $(wildcard $(ENVS_DIR)/aiops-platform.yaml),-f $(ENVS_DIR)/aiops-platform.yaml) \
		--set image.tag=$(PLATFORM_TAG) \
		--set backendUrl="$$BURL" \
		--set monitoringUrl="$$MURL" \
		--timeout $(HELM_TIMEOUT) \
		--wait \
		$(HELM_EXTRA_ARGS)

deploy-main-config:
	$(call helm_upgrade,main-config)

# ── Full deploy (bootstrap → secrets → infra → app, ordered) ───────
.PHONY: deploy-all
deploy-all: init-env deploy-infra
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
	$(MAKE) deploy-mcp-client ENV=$(ENV)
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
	$(MAKE) deploy-mcp-client ENV=$(ENV)
	$(MAKE) deploy-monitoring ENV=$(ENV)
	$(MAKE) deploy-migration-end ENV=$(ENV) HELM_EXTRA_ARGS='--set image.tag=$(MIGRATION_TAG)'
	$(MAKE) deploy-platform ENV=$(ENV)
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