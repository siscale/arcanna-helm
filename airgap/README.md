# Air-gapped install

Running Arcanna on a cluster that only has internet **during** installation (and
again briefly for upgrades). Two problems have to be solved: images must survive
the loss of internet, and pods must not try to re-pull from the public registries
once it's gone.

## Exact commands

Set these once per install — every command below reuses them. Replace the values
with your own; the examples use `registry.airgap.local:5000` and tag `v1.78.1`.

```bash
export REGISTRY=registry.airgap.local:5000       # your internal registry host[:port]
export ARCANNA_TAG=v1.78.1                        # Arcanna version to install
export RAG_TAG=v1.78.1                             # arcanna-rag version (often differs)
export GCR_JSON_KEY_FILE=~/gcr-sa.json            # GCP service-account JSON (private images)
export ENV=airgap
export NAMESPACE=arcanna-airgap
```

All commands are run from the repo root.

### Step 0 — prerequisites (while you still have internet)

```bash
# skopeo on the mirroring host (Debian/Ubuntu shown; use your distro's package)
sudo apt-get update && sudo apt-get install -y skopeo
skopeo --version

# Preview exactly what will be mirrored and where (no network calls, dry run)
./airgap/mirror-images.sh list
```

### Step 1 — mirror images into the internal registry

Pick **1a** or **1b**.

**1a. Direct** — the mirroring host can reach both the internet and `$REGISTRY`:

```bash
./airgap/mirror-images.sh direct
```

**1b. Archive** — internet host and registry are separate machines:

```bash
# On the internet-connected host — stage images into ./airgap-images/
./airgap/mirror-images.sh save

# Transfer the ./airgap-images/ directory across the gap (USB, one-way transfer, …).
# Then, on a host INSIDE the air-gap that can reach the registry:
export REGISTRY=registry.airgap.local:5000        # re-export on this host
./airgap/mirror-images.sh load
```

If your internal registry uses self-signed TLS or plain HTTP, add
`DEST_TLS_VERIFY=false`; if it needs a login, add `DEST_CREDS='user:pass'`:

```bash
DEST_TLS_VERIFY=false DEST_CREDS='pushuser:pushpass' ./airgap/mirror-images.sh direct
```

### Step 1b — also mirror the ECK & CFK operator images

These aren't in the script (versions depend on the operator release you install).
Mirror whatever your operator manifests reference, e.g.:

```bash
skopeo copy --dest-tls-verify=false \
  docker://docker.elastic.co/eck/eck-operator:2.16.1 \
  docker://$REGISTRY/eck/eck-operator:2.16.1

skopeo copy --dest-tls-verify=false \
  docker://confluentinc/confluent-for-kubernetes:2.11.2 \
  docker://$REGISTRY/confluentinc/confluent-for-kubernetes:2.11.2
```

### Step 2 — point every node at the internal registry

Run on **each** node (control-plane + workers), as root. `sudo -E` preserves the
exported `REGISTRY`. Add `INSECURE=true` for self-signed/HTTP, and
`REG_USER=… REG_PASS=…` if the registry requires auth to pull.

```bash
sudo -E ./airgap/setup-node-mirror.sh
# self-signed / HTTP registry:
# sudo -E INSECURE=true ./airgap/setup-node-mirror.sh
```

Then restart the runtime on that node so the config takes effect:

```bash
# RKE2 control-plane node:
sudo systemctl restart rke2-server
# RKE2 worker node:
sudo systemctl restart rke2-agent
# generic containerd:
sudo systemctl restart containerd
```

Verify a redirect works (should pull from your registry, not the internet):

```bash
# RKE2:
sudo /var/lib/rancher/rke2/bin/crictl pull gcr.io/siscale-aiops/component-worker:$ARCANNA_TAG
# generic containerd:
sudo crictl pull gcr.io/siscale-aiops/component-worker:$ARCANNA_TAG
```

### Step 3 — install Arcanna

The operators (ECK, CFK) and a storage class must already be in place — same
prerequisites as any install, just pulled from your mirror. Then:

```bash
make deploy-all ENV=$ENV NAMESPACE=$NAMESPACE TAG=$ARCANNA_TAG
```

Chart image references are unchanged (`gcr.io/…`, `docker.elastic.co/…`); the node
mirror redirects them to `$REGISTRY`. Watch progress with:

```bash
make status  ENV=$ENV NAMESPACE=$NAMESPACE
make healthcheck ENV=$ENV NAMESPACE=$NAMESPACE
```

You can now cut internet access.

### Upgrades (when internet briefly returns)

```bash
export ARCANNA_TAG=v1.79.0                          # the new version
./airgap/mirror-images.sh direct                    # mirror the new tag (or save→load)
make upgrade-all ENV=$ENV NAMESPACE=$NAMESPACE TAG=$ARCANNA_TAG
```

Nodes already point at the internal registry, so nothing on them changes.

## Why the `airgap` env

Generated from `envs/_template/` with `make init-env ENV=airgap`. It uses NodePort
exposure (no cloud LB/DNS needed) and, critically, sets `image.pullPolicy:
IfNotPresent` on every app workload so a pod restart after internet is cut does
**not** trigger a registry round-trip. The filebeat log-shipper sidecars, which
were hardcoded to `Always` in the chart templates, have also been switched to
`IfNotPresent` (affects all envs). `postgres`/`redis`/`admin-user` were already
`IfNotPresent`.

## Registry mirror vs. pre-pulling to nodes

**Use an internal registry mirror.** Pre-pulling images onto each node also works,
but the images are subject to kubelet image garbage collection (evicted under disk
pressure → `IfNotPresent` then fails), and must be re-done on every node that is
added or re-imaged. A registry that stays reachable inside the air-gap survives
reboots, scale-out, and GC, and it's the only option that also covers images
pulled by the ECK/CFK operators. The two scripts here implement the registry path.

## `mirror-images.sh` — copy images into the internal registry

Run from a host with internet (skopeo required). The destination reference keeps
the image path and only swaps the host (`gcr.io/siscale-aiops/x` →
`$REGISTRY/siscale-aiops/x`), which is exactly what the node mirror expects — so
**no chart edits are needed**.

| Command | Use when |
|---|---|
| `list`   | Print the full source→destination mapping (dry run) |
| `direct` | The host can reach both the internet and the internal registry |
| `save`   | Stage images into `./airgap-images/` for one-way transfer across the gap |
| `load`   | Push a transferred `./airgap-images/` into the registry (run inside the gap) |

Key env vars: `REGISTRY` (dest host[:port]), `ARCANNA_TAG` (all app images),
`RAG_TAG` (arcanna-rag, separate cadence), `GCR_JSON_KEY_FILE` (private gcr auth),
`DEST_CREDS` / `DEST_TLS_VERIFY` (internal registry auth/TLS).

### What gets mirrored

- **Arcanna app images** — 9 `gcr.io/siscale-aiops/*` repos at `ARCANNA_TAG`
  (rag at `RAG_TAG`). Private — need `GCR_JSON_KEY_FILE`.
- **Third-party data-plane** — `docker.elastic.co/beats/filebeat:8.19.9`,
  elasticsearch + kibana `8.17.0`, `confluentinc/cp-server:8.0.0` +
  `confluent-init-container:2.11.2`, `postgres:16.4`, `redis:7.4-alpine`.

> Versions are duplicated as constants at the top of `mirror-images.sh`. If you
> bump a chart's ES/Kibana/Kafka/PG/Redis/filebeat version, update the script too.

### Not covered by the script (mirror these separately)

The **ECK and CFK operators** are prerequisites installed outside these charts,
and each ships its own operator image (plus, for CFK, webhook/init images). Mirror
whatever your operator install manifests reference — versions depend on the
operator release you use.

## `setup-node-mirror.sh` — redirect the node runtime

Run on **every** node as root. Auto-detects RKE2 (writes
`/etc/rancher/rke2/registries.yaml`) vs. generic containerd (writes
`/etc/containerd/certs.d/<host>/hosts.toml`). Mirrors `gcr.io`,
`docker.elastic.co`, and `docker.io`. Options: `INSECURE=true` (self-signed/HTTP
registry), `REG_USER`/`REG_PASS` (registry auth), `RUNTIME=rke2|containerd`
(force). Restart the runtime afterward.

With the mirror in place the original `gcr-pull-secret` is irrelevant unless your
internal registry itself requires auth — the simplest setup is a read-only,
anonymous-pull internal registry inside the isolated network.

For upgrades, see the **Upgrades** commands at the end of the "Exact commands"
section above.
