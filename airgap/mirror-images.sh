#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Mirror every image Arcanna needs into an air-gapped registry, using skopeo.
#
# Run this from a host that has internet access (during your install window).
# Two workflows:
#
#   Direct (host can reach BOTH internet and the internal registry):
#       REGISTRY=registry.airgap.local:5000 GCR_JSON_KEY_FILE=~/gcr-sa.json \
#         ./mirror-images.sh direct
#
#   Archive (internet host and air-gapped registry are separate machines):
#       # on the internet-connected host:
#       GCR_JSON_KEY_FILE=~/gcr-sa.json ./mirror-images.sh save
#       # copy ./airgap-images/ across the gap (USB, one-way transfer, …), then
#       # on a host inside the air-gap that can reach the registry:
#       REGISTRY=registry.airgap.local:5000 ./mirror-images.sh load
#
# `./mirror-images.sh list` prints the full source→destination mapping and exits.
#
# Requires: skopeo (https://github.com/containers/skopeo).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config (override via environment) ────────────────────────────────────────
ARCANNA_TAG="${ARCANNA_TAG:-v1.78.1}"        # tag for all gcr.io/siscale-aiops app images
RAG_TAG="${RAG_TAG:-$ARCANNA_TAG}"           # arcanna-rag ships on its own cadence
REGISTRY="${REGISTRY:-}"                     # destination host[:port], e.g. registry.airgap.local:5000
GCR_JSON_KEY_FILE="${GCR_JSON_KEY_FILE:-}"   # GCP service-account JSON (private gcr.io images)
ARCHIVE_DIR="${ARCHIVE_DIR:-./airgap-images}" # local staging dir for save/load
DEST_TLS_VERIFY="${DEST_TLS_VERIFY:-true}"   # set false for a self-signed / plain-HTTP registry
DEST_CREDS="${DEST_CREDS:-}"                  # optional "user:pass" for the internal registry

# Infra image versions — keep in sync with charts/*/values.yaml.
FILEBEAT_VER="8.19.9"     # charts/*/values.yaml filebeat.image
ELASTIC_VER="8.17.0"      # charts/elasticsearch|kibana/values.yaml version
CP_SERVER_VER="8.0.0"     # charts/kafka/values.yaml image.application
CP_INIT_VER="2.11.2"      # charts/kafka/values.yaml image.init
POSTGRES_VER="16.4"       # charts/postgres/values.yaml image.tag
REDIS_VER="7.4-alpine"    # charts/redis/values.yaml image.tag

# Private Arcanna app images (all share ARCANNA_TAG, except rag).
GCR_IMAGES=(
  "gcr.io/siscale-aiops/aiops-rest-api-release:${ARCANNA_TAG}"     # aiops-rest-api + admin-user
  "gcr.io/siscale-aiops/aiops-platform-release:${ARCANNA_TAG}"     # frontend
  "gcr.io/siscale-aiops/aiops-mcp-client:${ARCANNA_TAG}"           # mcp-client
  "gcr.io/siscale-aiops/component-core-standalone:${ARCANNA_TAG}"  # core-framework
  "gcr.io/siscale-aiops/component-migration:${ARCANNA_TAG}"        # migration jobs
  "gcr.io/siscale-aiops/component-webservice:${ARCANNA_TAG}"       # cacher/exposer/feedbacker/hypervisor/monitoring
  "gcr.io/siscale-aiops/component-worker:${ARCANNA_TAG}"           # worker/buckets-updater/clustering/retrainer
  "gcr.io/siscale-aiops/agents-component:${ARCANNA_TAG}"           # agents-exposer
  "gcr.io/siscale-aiops/arcanna-rag:${RAG_TAG}"                    # rag (manual deploy)
)

# Public third-party images. Note: ECK/CFK pull the elastic/confluent data-plane
# images below, but the ECK and CFK *operators* themselves are installed
# separately — mirror their operator images too (versions depend on your install).
PUBLIC_IMAGES=(
  "docker.elastic.co/beats/filebeat:${FILEBEAT_VER}"
  "docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VER}"
  "docker.elastic.co/kibana/kibana:${ELASTIC_VER}"
  "docker.io/confluentinc/cp-server:${CP_SERVER_VER}"
  "docker.io/confluentinc/confluent-init-container:${CP_INIT_VER}"
  "docker.io/library/postgres:${POSTGRES_VER}"
  "docker.io/library/redis:${REDIS_VER}"
)

ALL_IMAGES=("${GCR_IMAGES[@]}" "${PUBLIC_IMAGES[@]}")

# ── Helpers ──────────────────────────────────────────────────────────────────
# Destination reference: swap the upstream host for $REGISTRY, keep the path.
#   gcr.io/siscale-aiops/x:tag        -> $REGISTRY/siscale-aiops/x:tag
#   docker.io/library/postgres:16.4   -> $REGISTRY/library/postgres:16.4
# This is exactly what a containerd/RKE2 registry mirror expects (host-only swap),
# so the charts keep their original image references — see setup-node-mirror.sh.
dest_ref() { echo "${REGISTRY}/${1#*/}"; }

# Local archive path for an image (dir: transport, one dir per image).
archive_path() { echo "${ARCHIVE_DIR}/$(echo "$1" | tr '/:' '__')"; }

need_skopeo() { command -v skopeo >/dev/null || { echo "❌ skopeo not found — install it first"; exit 1; }; }

src_creds_args() {
  # Only gcr.io images are private.
  if [[ "$1" == gcr.io/* ]]; then
    [[ -n "$GCR_JSON_KEY_FILE" && -f "$GCR_JSON_KEY_FILE" ]] \
      || { echo "❌ GCR_JSON_KEY_FILE must point to the GCP SA JSON for $1" >&2; exit 1; }
    printf -- '--src-creds\n_json_key:%s\n' "$(cat "$GCR_JSON_KEY_FILE")"
  fi
}

dest_creds_args() {
  [[ -n "$DEST_CREDS" ]] && printf -- '--dest-creds\n%s\n' "$DEST_CREDS"
}

require_registry() { [[ -n "$REGISTRY" ]] || { echo "❌ set REGISTRY=host[:port]"; exit 1; }; }

# ── Sub-commands ─────────────────────────────────────────────────────────────
cmd_list() {
  printf '%-70s -> %s\n' "SOURCE" "DESTINATION (\$REGISTRY=${REGISTRY:-<unset>})"
  for img in "${ALL_IMAGES[@]}"; do
    printf '%-70s -> %s\n' "$img" "$(dest_ref "$img")"
  done
}

cmd_direct() {
  need_skopeo; require_registry
  for img in "${ALL_IMAGES[@]}"; do
    echo "──── copy $img -> $(dest_ref "$img") ────"
    mapfile -t sc < <(src_creds_args "$img"); mapfile -t dc < <(dest_creds_args)
    skopeo copy --all --retry-times 3 \
      "${sc[@]}" "${dc[@]}" \
      --dest-tls-verify="$DEST_TLS_VERIFY" \
      "docker://$img" "docker://$(dest_ref "$img")"
  done
  echo "✅ all images mirrored to $REGISTRY"
}

cmd_save() {
  need_skopeo
  mkdir -p "$ARCHIVE_DIR"
  for img in "${ALL_IMAGES[@]}"; do
    echo "──── save $img -> $(archive_path "$img") ────"
    mapfile -t sc < <(src_creds_args "$img")
    rm -rf "$(archive_path "$img")"
    skopeo copy --all --retry-times 3 "${sc[@]}" \
      "docker://$img" "dir:$(archive_path "$img")"
    # Record the original ref so `load` knows the destination path.
    echo "$img" > "$(archive_path "$img")/.source-ref"
  done
  echo "✅ images staged in $ARCHIVE_DIR — transfer this dir into the air-gap, then run: load"
}

cmd_load() {
  need_skopeo; require_registry
  for d in "$ARCHIVE_DIR"/*/; do
    [[ -f "$d/.source-ref" ]] || continue
    img="$(cat "$d/.source-ref")"
    echo "──── load $(archive_path "$img") -> $(dest_ref "$img") ────"
    mapfile -t dc < <(dest_creds_args)
    skopeo copy --all --retry-times 3 "${dc[@]}" \
      --dest-tls-verify="$DEST_TLS_VERIFY" \
      "dir:${d%/}" "docker://$(dest_ref "$img")"
  done
  echo "✅ all staged images pushed to $REGISTRY"
}

case "${1:-}" in
  list)   cmd_list ;;
  direct) cmd_direct ;;
  save)   cmd_save ;;
  load)   cmd_load ;;
  *) echo "usage: $0 {list|direct|save|load}"; exit 1 ;;
esac
