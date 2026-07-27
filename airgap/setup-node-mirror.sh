#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Point a node's container runtime at the internal air-gapped registry, so that
# existing image references (gcr.io/…, docker.elastic.co/…, docker.io/…) are
# transparently pulled from $REGISTRY without editing any chart.
#
# The mirror preserves the image path and only swaps the host — exactly how
# mirror-images.sh pushes images. So gcr.io/siscale-aiops/component-worker:tag
# is served from $REGISTRY/siscale-aiops/component-worker:tag.
#
# Run on EVERY node (control-plane + workers), as root:
#     REGISTRY=registry.airgap.local:5000 sudo -E ./setup-node-mirror.sh
#
# Options (env):
#   RUNTIME=rke2|containerd   Force runtime (default: auto-detect)
#   INSECURE=true             Internal registry is self-signed / plain HTTP
#   REG_USER / REG_PASS       Credentials if the internal registry requires auth
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REGISTRY="${REGISTRY:-}"
INSECURE="${INSECURE:-false}"
REG_USER="${REG_USER:-}"
REG_PASS="${REG_PASS:-}"
[[ -n "$REGISTRY" ]] || { echo "❌ set REGISTRY=host[:port]"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "❌ run as root (sudo -E)"; exit 1; }

UPSTREAMS=(gcr.io docker.elastic.co docker.io)

# Auto-detect runtime unless forced.
RUNTIME="${RUNTIME:-}"
if [[ -z "$RUNTIME" ]]; then
  if [[ -d /etc/rancher/rke2 ]] || command -v rke2 >/dev/null 2>&1; then
    RUNTIME=rke2
  else
    RUNTIME=containerd
  fi
fi
echo "▶ runtime: $RUNTIME   registry: $REGISTRY   insecure: $INSECURE"

case "$RUNTIME" in
# ── RKE2 (uses its own registries.yaml, NOT certs.d) ─────────────────────────
rke2)
  F=/etc/rancher/rke2/registries.yaml
  mkdir -p "$(dirname "$F")"
  {
    echo "mirrors:"
    for u in "${UPSTREAMS[@]}"; do
      echo "  \"$u\":"
      echo "    endpoint:"
      echo "      - \"https://$REGISTRY\""
    done
    echo "configs:"
    echo "  \"$REGISTRY\":"
    if [[ -n "$REG_USER" ]]; then
      echo "    auth:"
      echo "      username: \"$REG_USER\""
      echo "      password: \"$REG_PASS\""
    fi
    if [[ "$INSECURE" == "true" ]]; then
      echo "    tls:"
      echo "      insecure_skip_verify: true"
    fi
  } > "$F"
  echo "✅ wrote $F"
  echo "   Restart the node agent to apply:"
  echo "     systemctl restart rke2-server   # control-plane"
  echo "     systemctl restart rke2-agent     # workers"
  ;;

# ── Generic containerd (certs.d hosts.toml) ──────────────────────────────────
containerd)
  BASE=/etc/containerd/certs.d
  for u in "${UPSTREAMS[@]}"; do
    mkdir -p "$BASE/$u"
    {
      echo "server = \"https://$u\""
      echo "[host.\"https://$REGISTRY\"]"
      echo "  capabilities = [\"pull\", \"resolve\"]"
      [[ "$INSECURE" == "true" ]] && echo "  skip_verify = true"
    } > "$BASE/$u/hosts.toml"
    echo "✅ wrote $BASE/$u/hosts.toml"
  done
  CFG=/etc/containerd/config.toml
  if ! grep -q 'config_path.*certs.d' "$CFG" 2>/dev/null; then
    echo ""
    echo "⚠  containerd must be told to read certs.d. Ensure $CFG contains:"
    echo "     [plugins.\"io.containerd.grpc.v1.cri\".registry]"
    echo "       config_path = \"/etc/containerd/certs.d\""
    echo "   then: systemctl restart containerd"
  else
    echo "   Apply with: systemctl restart containerd"
  fi
  [[ -n "$REG_USER" ]] && echo "⚠  registry auth via certs.d requires a [host.\"…\"].auth or CRI config — see docs."
  ;;
*) echo "❌ unknown RUNTIME=$RUNTIME"; exit 1 ;;
esac
