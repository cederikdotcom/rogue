# Runbook: run rogue through the Linux container pipeline

This runbook gives the exact end-to-end steps to build and deploy rogue through
the two-service Linux container pipeline (issue #508), once both services are
deployed. It supersedes the single-watcher, do-everything flow of issue #492:
in #508 the git watcher only reports a build, and two platform services own the
build and the deploy.

Nothing in this runbook changes rogue's game code. It documents how the
existing `Dockerfile` (the C rogue plus the Go `rogue-web` bridge, plain HTTP on
`:8080`, no `VOLUME`, state on `/data`) is built and delivered by the pipeline.

## The two services and the seam

The pipeline is the Apple-convention pattern applied to Linux containers, split
across three axes:

- watchers by VCS: `hydragitwatcher` (git) reports each push.
- pipeline by platform: `hydralinuxpipeline` (control plane, peer of
  `hydraapplepipeline`) owns the job model and the target-scale deploy.
- builder manager by platform: `hydrapipelinerunnerlinux` (peer of
  `hydrapipelinerunnerapple`, server-side only) places, provisions, dispatches,
  and tears down the ephemeral builder.

The seam between a watcher and the pipeline is the SCM-agnostic build-notify
shape, the four fields `hydracluster` already normalises:

```json
{ "watch_name": "rogue", "scm_type": "git", "scm_ref": "v1.0.0",
  "build_url": "<clone/build source ref>" }
```

Any watcher that emits these four fields feeds any platform pipeline. The
pipeline carries `scm_type` and `scm_ref` through untouched and treats
`build_url` as the clone source. It is not coupled to git or Perforce.

## rogue's target architecture: arm64, native

rogue's production home is the Pi fleet, which is arm64. The scale image
compiles C (gcc plus libncurses), so a foreign-arch build under QEMU is slow
and flaky. The pipeline therefore builds each platform NATIVELY: the builder
arch equals the target arch, and arm64 is never emulated.

For arm64 that means one of two builder tiers:

- Tier 1 (preferred): a rootless BuildKit builder scale on a fleet node whose
  `Arch` is arm64 and that has spare capacity. Cheapest, and the registry layer
  cache is already warm.
- Tier 2 (on-demand): if no arm64 fleet node qualifies, an on-demand hcloud
  `cax` server (native arm64, ubuntu-24.04) is created, `hydraskin install`ed,
  used for the one build, then destroyed.

rogue declares both `linux/arm64` and `linux/amd64` in `.hydrabuild.yaml`
(`build.platforms`); each is built on its own native builder. arm64 is the one
that must be present for the Pi fleet, so it is the platform this runbook keeps
front and centre.

## Delivery: scaleregistry plus hydraskin, never HydraRelease

Scales are their own vertical. The runner pushes the built image to
`scaleregistry.experiencenet.com/rogue:<tag>`, and `hydralinuxpipeline`
launches or updates the scale on the target node with a `ScaleOp` through the
`hydracluster` generic op-relay (#497), applying `user.hydra.*` labels. Scales
do NOT go through HydraRelease or HydraExperienceLibrary. That path is only for
released binaries, not container scales.

## Prerequisites (both services already deployed)

Confirm all of the following before a live run. The preflight script
(`scripts/linux-pipeline-preflight.sh`) checks the ones it can read without
mutating anything and prints a go/no-go.

- `hydracluster` runs the generic op-relay of #497 (branch
  `scale-op-delegation-scoped-tokens-497` at time of writing). Both new services
  mutate ONLY through the op-relay (`POST /api/v1/nodes/{id}/ops`) with a scoped
  op-token; neither ever calls `/exec`. If the op-relay is not merged and live,
  the pipeline cannot deploy.
- `hydralinuxpipeline` is deployed at `linuxpipeline.experiencenet.com` with:
  `server.admin_token`, `runner.url` and `runner.token` (to reach the runner),
  `cluster.url` and `cluster.op_token` (to launch the target scale), and
  `server.apply: true` (or the `--apply` flag). Without `--apply` it runs in
  dry-run and touches no live scale.
- `hydrapipelinerunnerlinux` is deployed with: `cluster.url`,
  `cluster.readonly_token` (fleet inventory), `cluster.op_token` (launch and
  remove builder scales), `scaleregistry.{host,user,token}`, `builder.image`
  (`scaleregistry.experiencenet.com/hydra-builder`), `hcloud.token` (Tier 2
  only), and `--apply`. It ships and starts in dry-run; an operator opts in.
- The `hydra-builder` image exists in the scale registry for the target
  arch(es), rootless BuildKit recipe (#502-A): `buildkitd
  --oci-worker-no-process-sandbox`, unprivileged, DHCP, registry auth inside
  the builder.
- Native arm64 builder capacity is available: either an online arm64 fleet node
  with headroom above its production reserve (Tier 1), or hcloud budget and
  token for a `cax` server (Tier 2). The runner refuses placement rather than
  starve a production node (the Pi OOM guardrail), so at least one path must
  have room.
- `hydragitwatcher` is deployed and watching `cederikdotcom/rogue`, configured
  to emit build-notify to `hydralinuxpipeline` on a `v*` tag (deploy) and,
  optionally, on a branch push (build only).
- DNS: an explicit A record `rogue.experiencenet.com -> 141.227.136.199` (the
  Brussels edge) exists and resolves globally. There is no `*.experiencenet.com`
  wildcard. Create the record BEFORE the scale is routed, or Traefik's first
  ACME attempt hits NXDOMAIN and backs off.
- `.hydrabuild.yaml` is present at the repo root of the built commit, declaring
  `scale.{name,domain,port,health_path,disk}` and `build.{dockerfile,context,
  platforms}`. rogue: name `rogue`, domain `rogue.experiencenet.com`, port
  `8080`, health_path `/`, platforms `linux/arm64` and `linux/amd64`.

## End-to-end: git push to serving

### Step 1 - push a tag

The push is the only manual trigger. Everything after it is automatic.

```sh
git -C <repo> tag v1.0.0
git -C <repo> push origin v1.0.0
```

`hydragitwatcher` sees the `v*` tag on `cederikdotcom/rogue` and POSTs
build-notify to the pipeline:

```
POST https://linuxpipeline.experiencenet.com/api/v1/builds/notify
Authorization: Bearer <admin_token>
{ "watch_name": "rogue", "scm_type": "git", "scm_ref": "v1.0.0",
  "build_url": "<clone source for the tagged commit>" }
```

The pipeline validates `watch_name`, creates a job in state `queued`, emits a
`job.created` event, and returns `202 { "id": "<job_id>" }`.

### Step 2 - the pipeline asks the runner for a builder and image

The pipeline moves the job to `building` and calls the runner:

```
POST {runner.url}/api/v1/builds
Authorization: Bearer <runner.token>
{ "job_id": "...", "watch_name": "rogue", "scm_ref": "v1.0.0",
  "build_url": "...", "platforms": ["linux/arm64","linux/amd64"],
  "image_name": "rogue", "tag": "v1.0.0" }
```

The runner owns placement, provision, dispatch, and teardown. The pipeline only
asks for "a builder plus a pushed image" and receives the digest back.

### Step 3 - the runner places a native builder (arch plus capacity)

For each requested platform the runner reads the fleet inventory
(`GET {cluster.url}/api/v1/nodes` with the read-only token) and finds nodes
where `Arch` matches the target arch, `Status` is online, and `SkinHost`
metrics are readable. It computes headroom (free memory, load per core) and
applies the Pi OOM guardrail: if no candidate has room for the builder without
dropping a production node below its reserve, it REFUSES Tier 1 and either falls
back to Tier 2 or fails the job with a clear reason. A nil or unreadable
`SkinHost` is treated as "no headroom known" and is not eligible (fail-safe).

- arm64: pick an arm64 fleet node with the most headroom (Tier 1), or create an
  hcloud `cax` server (Tier 2).
- amd64: pick an amd64 fleet node (Tier 1), or an hcloud `cx`/`cpx` server
  (Tier 2).

Tier 1 launches the builder as an ephemeral scale through the op-relay:
`ScaleOp{Verb:"launch", Scale:"builder-<jobid>", Image:hydra-builder,
Isolation:"unprivileged", Internal:true, Resources:{Memory:...},
Labels:{"user.hydra.autoupdate":"off"}}`. `Internal:true` means no expose
device: the builder needs only outbound access to the registry and the SCM host,
and it takes a DHCP address, never a static IP.

### Step 4 - the runner dispatches the build (native, cached, pushed)

Inside the builder, rootless BuildKit runs. Registry auth lives inside the
builder (docker config or a BuildKit secret, fed by password-stdin so the token
never reaches argv). The build clones the context and runs buildctl:

```
buildctl build --frontend dockerfile.v0 \
  --local context=<ctx> --local dockerfile=<ctx> --opt filename=Dockerfile \
  --output type=image,name=scaleregistry.experiencenet.com/rogue:v1.0.0,push=true \
  --export-cache type=registry,ref=scaleregistry.experiencenet.com/rogue:buildcache,mode=max \
  --import-cache type=registry,ref=scaleregistry.experiencenet.com/rogue:buildcache
```

The registry-backed cache warms a freshly provisioned builder from the previous
build. The build is native for the builder's arch (no `--platform` cross-build,
no QEMU). On success the builder returns the pushed manifest digest.

The runner records `building -> pushed`, then tears the builder down. Teardown
ALWAYS runs, on success and on failure, through a deferred step: Tier 1 sends
`ScaleOp{Verb:"remove", Scale:"builder-<jobid>"}`; Tier 2 does `hcloud server
delete`. A builder never lingers; the durable value is the image and the cache
in the registry.

The runner returns `{ status:ok, digest, image, node|node_type }` to the
pipeline, which records `Image` and `Digest` and moves the job to `pushed`.

### Step 5 - the pipeline launches or updates the target scale

The pipeline moves the job to `deploying` and enqueues a target `ScaleOp`
through the op-relay on the target node:

```
ScaleOp{
  Verb:   "launch" (first deploy) | "update" (redeploy),
  Scale:  "rogue", Project: <project>,
  Image:  { Repo: <alias-resolved rogue repo>, Tag: "v1.0.0" },
  Digest: <pushed manifest digest>,
  Isolation: "unprivileged",
  Disks:  [ { path: "/data", size: "2GiB" } ],
  Expose: { Port: 8080, Domain: "rogue.experiencenet.com", HealthPath: "/" },
  Labels: {
    "user.hydra.image_digest": <digest>,
    "user.hydra.health_path":  "/",
    "user.hydra.autoupdate":   "off"
  }
}
```

Labels are `user.hydra.*` only. The `ScaleOp` type carries no `Command` field
and no CPU pin on the apply path (safety-by-type). The enqueue is
`POST {cluster.url}/api/v1/nodes/{targetNodeID}/ops` with the op-token; the
pipeline then polls `GET .../ops/{opId}/result` until it gets a
`ScaleOpResult`. The op store is in-memory and ephemeral (dropped on cluster
restart, capped at 50 results), so a missing result is retried with bounded
backoff, not treated as fatal.

On `ScaleOpResult.Status == ok` the job goes `live`. `update` is idempotent by
digest, so a retried deploy does not double-launch. `hydrascalerouter` sees the
`user.hydra.domain`/`port`/`health_path` labels, requests a Let's Encrypt
certificate, and serves within about 30 seconds. Routing is dynamic from the
labels; never add a static route.

### Step 6 - observe

- `GET /api/v1/builds` lists the local job records (state, `scm_ref`, arch,
  `image:tag`, node, updated).
- `GET /api/v1/builds/{id}` is the single job.
- `GET /admin` is the dashboard: a job table with state badges, live-updated
  over the SSE stream at `GET /api/v1/events`.
- `POST /api/v1/builds/{id}/retry` re-enqueues a failed job.

## Acceptance checks

```sh
# both arches present in the manifest (arm64 is required for the Pi fleet)
docker buildx imagetools inspect scaleregistry.experiencenet.com/rogue:v1.0.0

# the site serves with a valid cert
curl -sI https://rogue.experiencenet.com/          # 200, Let's Encrypt cert
curl -s  https://rogue.experiencenet.com/scores    # top ten renders

# a live game works
#   open wss://rogue.experiencenet.com/ws in the browser client
```

Confirm the scale labels are `user.hydra.domain=rogue.experiencenet.com`,
`user.hydra.port=8080`, `user.hydra.health_path=/`, and that
`user.hydra.image_digest` matches the pushed digest. Confirm a save under
`/data` survives a redeploy.

## Dry-run first

Both services default to dry-run. With `--apply` off, the pipeline still creates
the job and advances the states for observability, but marks the deploy as a
simulated result and touches no live scale; the runner assembles the exact
buildctl, docker-login, op-relay, and hcloud commands and logs each as
`[dry-run] skipping <action> (pass --apply to run)` without executing it. Run
the whole flow in dry-run once and read the logs and the dashboard before an
operator sets `--apply`.

## Rollback

Redeploy the previous tag: push it again (or `POST /api/v1/builds/{id}/retry`
on the previous good job), and the pipeline issues an idempotent `update`
`ScaleOp` pinned to that image digest. State on `/data` is a host-side disk
device and is untouched by an image swap.

## Known risks (see #508 / #502 for detail)

- Op-store ephemerality: a cluster restart mid-deploy can drop the op result and
  hang a job in `deploying`. The pipeline caps the wait and then fails the job
  with an "op result not returned" detail rather than blocking forever.
- Op-relay dependency: #497 must be merged and live in `hydracluster`. Do not
  fall back to `/exec`; that would break the "op-token cannot exec" invariant.
- Pi OOM guardrail tuning: the reserve margin is configurable and defaults
  conservative. Too high and nothing places; too low and a production node can
  OOM. Nil metrics mean ineligible.
- Tier 2 orphan cost: a crash between `hcloud server create` and `delete` leaks
  a paid node. Teardown is deferred and retried, and a startup reaper destroys
  stragglers labelled `hydra-builder`.
- Rootless BuildKit fragility: a Dockerfile that needs privileged syscalls can
  fail under `--oci-worker-no-process-sandbox`. rogue's Dockerfile is a plain
  gcc/make plus Go build and is known to work rootless. If a future change needs
  more privilege, the failure is surfaced clearly; do not silently escalate.
