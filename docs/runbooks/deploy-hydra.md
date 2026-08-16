# Runbook: deploy rogue on Hydra (hydraskin)

> **Automated now:** a `v*` tag drives the full git-push-to-deploy path
> (build + push + launch) via **hydragitwatcher**, reading the root
> [`.hydrabuild.yaml`](../../.hydrabuild.yaml). See
> [first-pipeline-test.md](first-pipeline-test.md). That supersedes the
> "launch is a separate manual step" flow below, which stays as the manual
> fallback. `.github/workflows/deploy-image.yml` also still publishes the
> image on a `v*` tag (belt and braces).

This deploys rogue the way HydraMancer's `/deploy` quickstart describes:
rogue-web is "a container that speaks HTTP", so it runs as a **scale** on a
hydraskin node with automatic HTTPS on a `*.experiencenet.com` domain. No
server to rent, no certificates to manage — the standalone Caddy box in
`web/deploy/provision.sh` is the alternative, not this.

## What is already in the repo

- `Dockerfile` — multi-arch image (amd64 + arm64) building the C rogue (with
  `-DNO_SHELL_ESCAPE`) and the Go rogue-web bridge, serving plain HTTP on
  `:8080`. No `VOLUME`; state lives on `/data`.
- `.github/workflows/deploy-image.yml` — on a `v*` tag, builds and pushes
  `scaleregistry.experiencenet.com/rogue:<version>` and `:latest`.

## One-time repo setup

The workflow needs the scale-registry credentials, same as every other Hydra
service. Set them on the `cederikdotcom/rogue` repo:

```sh
gh variable set SCALE_REGISTRY      -R cederikdotcom/rogue --body scaleregistry.experiencenet.com
gh variable set SCALE_REGISTRY_USER -R cederikdotcom/rogue --body hydra
gh secret   set SCALE_REGISTRY_TOKEN -R cederikdotcom/rogue --body '<the hydra push token>'
```

The variables are not secret and are set already. The **token is a secret** —
it is the same push token the hydramancer repo uses. It cannot be read back
from another repo, so it has to be provided once here.

## Step 1 — publish the image

```sh
git -C <repo> tag v1.0.0
git -C <repo> push origin v1.0.0
```

The workflow builds both architectures and pushes to the scale registry.
Confirm the arm64 manifest is present (the Pi fleet is arm64; an amd64-only
image cannot be scheduled).

## Step 2 — launch it as a scale

Run on a hydraskin node via `hydracluster exec`. `node-50ab5309`
(pi-node-004-nvme) is a working hydraskin node.

```sh
HC=/home/claude-user/hydracluster/bin/hydracluster
S=https://hydracluster.experiencenet.com
T=<hydracluster admin token from ~/.hydracluster/config.yaml>
NODE=node-50ab5309

$HC exec $NODE "/usr/bin/incus launch scaleregistry.experiencenet.com/rogue:v1.0.0 rogue" --server "$S" --admin-token "$T"

# persistent game state (saves, score, lock) on the host, never in the image
$HC exec $NODE "/usr/bin/incus config device add rogue state disk source=/srv/scales/rogue path=/data shift=true" --server "$S" --admin-token "$T"
$HC exec $NODE "/usr/bin/incus restart rogue" --server "$S" --admin-token "$T"
```

## Step 3 — give it a domain

rogue serves `/` (the game page returns 200), so no `health_path` is needed.

```sh
$HC exec $NODE "/usr/bin/incus config set rogue user.hydra.domain=rogue.experiencenet.com" --server "$S" --admin-token "$T"
$HC exec $NODE "/usr/bin/incus config set rogue user.hydra.port=8080" --server "$S" --admin-token "$T"
```

hydrascalerouter discovers the labelled scale, requests a Let's Encrypt
certificate, and starts serving within about 30 seconds. Routing is dynamic
from these labels — never add a static route in `routes.json`.

## Step 4 — point DNS at the district ingress

Create an A record for `rogue.experiencenet.com` at the district ingress
(the same ingress hydramancer uses: hydraguard-brussels, 141.227.136.199).
Use the `hydraexperiencenet` hcloud context. Set TTL 60 before cutover.

```sh
export HCLOUD_CONTEXT=hydraexperiencenet
hcloud zone rrset create --name rogue --type A --record 141.227.136.199 --ttl 60 experiencenet.com
```

## Verify

```sh
curl -sI https://rogue.experiencenet.com/            # 200, valid cert
curl -s  https://rogue.experiencenet.com/scores      # top ten
```

## Operations

Same shape as any scale — no systemd inside the container.

```sh
$HC exec $NODE "/usr/bin/incus restart rogue" --server "$S" --admin-token "$T"       # restart
$HC exec $NODE "/usr/bin/incus exec rogue -- ls /data /data/saves" --server "$S" --admin-token "$T"  # inspect state
```

To ship a new version: tag it (step 1), then `hydraskin update rogue --tag vX.Y.Z --apply` on the node, or `incus stop rogue && incus rebuild scaleregistry.experiencenet.com/rogue:vX.Y.Z rogue && incus start rogue`.

## Verified deployment (2026-08-16) — first live run

rogue went live at https://rogue.experiencenet.com as a scale on
pi-node-004 (node-50ab5309), running the pipeline stages by hand. Real
notes and gotchas from that run:

- **Registry credential**: user `hydra`, token in `/etc/hydrascaleregistry/config.yaml`
  on the registry host (releasesandscaleregistry, 159.69.93.219). `docker login
  scaleregistry.experiencenet.com -u hydra`.
- **Multi-arch build**: `docker buildx build --platform linux/amd64,linux/arm64
  --push` on an amd64 box with `qemu-user-static` + `tonistiigi/binfmt`. The
  target Pi is arm64, so arm64 is required. The Dockerfile passes
  `./configure --build=$(uname -m)-unknown-linux-gnu` because config.guess
  fails under QEMU emulation.
- **Launch** (via `hydracluster exec` on the node): the OCI image ref for the
  node's incus remote is `scaleregistry:rogue:v1.0.0` (not the full URL).
  `incus create scaleregistry:rogue:v1.0.0 rogue`, then
  `incus config device add rogue state disk source=/srv/scales/rogue path=/data shift=true`,
  then labels `user.hydra.domain=rogue.experiencenet.com`,
  `user.hydra.port=8080`, `user.hydra.health_path=/`, then `incus start rogue`.
- **DNS is an explicit A record, not a wildcard**. There is no
  `*.experiencenet.com`; each scale has its own A record to the edge
  (141.227.136.199). Create it in the `hydraexperiencenet` context:
  `hcloud zone rrset create --name rogue --type A --record 141.227.136.199 experiencenet.com`.
- **Create DNS BEFORE the scale is routed**. Traefik requests the cert as soon
  as the router sees the label; if the A record is not yet globally resolvable,
  the HTTP-01 challenge fails with NXDOMAIN and Traefik backs off. If that
  happens, once DNS resolves, force a re-issue with
  `sudo systemctl restart traefik` on the edge (brief blip for all edge
  services). Poll the cert with `openssl s_client ... | openssl x509 -issuer`
  until the issuer is Let's Encrypt.
- **Verified**: valid cert, `/`, `/help`, `/scores`, and a live game over
  `wss://rogue.experiencenet.com/ws` all work; game state persists to `/data`.

This was a manual execution of the pipeline stages. The automated
git-push-to-deploy loop (hydragitwatcher receiving a push and doing all of the
above) is the remaining work tracked in #492.
