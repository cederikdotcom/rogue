# Runbook: rogue as the first git-push-to-deploy test (#492)

Rogue is the first workload run end to end through the new git pipeline. This
runbook is the operator script for that first live run: request a repo, push
rogue, watch the image get built, see the scale come up at
`rogue.experiencenet.com`, and verify it. It supersedes the "deploying the
pushed image is a separate manual step" note in
[`deploy-hydra.md`](deploy-hydra.md): with the pipeline in place, a `v*` tag
drives build **and** deploy automatically. `deploy-hydra.md` stays valid as
the manual fallback, and `.github/workflows/deploy-image.yml` stays in place as
a belt-and-braces image publish.

## The moving parts

| Piece | Role in this test |
| --- | --- |
| **hydramancer** `/deploy` | Creator-facing front door. Signs the creator in (iamnim), proxies the repo request. Holds no credentials. |
| **hydragitprovision** | Localhost-bound, next to Gitea. Verifies the iamnim session + org membership, then mints the Gitea org/account/repo and adds the creator as a WRITE collaborator. Returns the clone URL and a one-time temp password. |
| **Gitea** at `git.experiencenet.com` | The git server we control. Fires the push webhook. |
| **hydragitwatcher** | Runs as a scale. Receives the push webhook, builds multi-arch on the BuildKit builders, pushes to the registry, drives `hydraskin` to launch/update the scale, sets labels, ensures DNS, reports state. |
| **BuildKit builder scales** | Two native `buildkitd` daemons — amd64 on an hcloud node, arm64 on a Pi — federated by `buildx` as the `hydra` builder, mesh-exposed on `tcp://<mesh>:1234`. No QEMU. |
| **This repo** | The workload under test. `Dockerfile` builds the image; `.hydrabuild.yaml` declares where and how to run it. |

## What this repo already provides

- `Dockerfile` — multi-arch (amd64 + arm64), builds the C rogue with
  `-DNO_SHELL_ESCAPE` and the Go rogue-web bridge, plain HTTP on `:8080`, no
  `VOLUME`, state on `/data`, `HYDRA_AUTO_UPDATE=off`.
- `.hydrabuild.yaml` — the scale-deploy intent the watcher reads:
  `name: rogue`, `domain: rogue.experiencenet.com`, `port: 8080`,
  `health_path: /`, `disk: /data (2GiB)`, `platforms: amd64 + arm64`.
- `.github/workflows/deploy-image.yml` — the independent image publish that
  also fires on `v*` (kept as a fallback / second source of the image).
- `scripts/first-pipeline-test.sh` — the preflight below, runnable now.

## The one human-provided secret

Everything else in this pipeline is code or config in a repo. The single
secret a human must place by hand is the **scale-registry push token**:

- **What:** the `hydra` registry user's push token for
  `scaleregistry.experiencenet.com`.
- **Where it now lives:** in **hydragitwatcher's config** (`registry.token`),
  which propagates it to both `buildkitd` daemons at build time. This is the
  shift from the old model, where the token lived in this repo's GitHub Actions
  secret (`secrets.SCALE_REGISTRY_TOKEN`) for `deploy-image.yml`. That repo
  secret is still valid for the fallback workflow, but the **pipeline's** copy
  of the token is the watcher's.
- **Never** commit it, never print it, never put it in `.hydrabuild.yaml`.

---

## Part A — preflight (no production mutation)

Run the preflight script from a clone of this repo. It only reads and dry-runs;
it writes nothing to the registry, no node, and no DNS record.

```sh
scripts/first-pipeline-test.sh            # assert prerequisites + print go/no-go
scripts/first-pipeline-test.sh --build    # also dry-run the multi-arch build (needs buildx)
```

It checks the `.hydrabuild.yaml` fields, confirms the Dockerfile invariants
(`:8080`, no `VOLUME`, `HYDRA_AUTO_UPDATE`, `NO_SHELL_ESCAPE`), resolves
`rogue.experiencenet.com` read-only to confirm the wildcard covers it, and
prints the exact go/no-go operator steps below. With `--build` it runs
`docker buildx build --platform linux/amd64,linux/arm64` with **no `--push`**
(output `type=cacheonly`) to prove the image builds multi-arch and the
watcher's build command string is correct.

---

## Part B — the live run (operator)

These steps mutate live infrastructure. They are **not** run by scaffolding —
an operator runs them, in order, once the preflight is green.

### B0. Prerequisites are deployed

- `hydragitprovision` is running (systemd, localhost) next to Gitea, holding
  the Gitea admin token.
- The two `buildkitd` builder scales are up and mesh-reachable
  (`tcp://<amd64-mesh>:1234`, `tcp://<arm64-mesh>:1234`).
- `hydragitwatcher` is deployed as a scale with a watch on `cyborn/rogue`
  (`ref: refs/tags/v*`), its `registry.token` set, and its `hydracluster`
  admin token set.

### B1. Request the repo

The creator signs in at hydramancer `/deploy` (302 to iamnim `/login`,
`iamnim_session` cookie set on return), then the git access panel POSTs:

```json
{ "kind": "git", "org_slug": "cyborn", "name": "rogue" }
```

hydramancer forwards it (with `X-Iamnim-Session`, no credentials) to
hydragitprovision, which returns once:

```json
{
  "endpoint": "https://git.experiencenet.com/cyborn/rogue.git",
  "login": "<creator-login>",
  "scope": "write",
  "temp_password": "<shown once>"
}
```

Save the `temp_password` now — it is returned only on first creation.

### B2. Push rogue and tag it

Push this repo's tree (including `Dockerfile`, `.hydrabuild.yaml`, and
`deploy-image.yml`) to the provisioned repo, then tag a version:

```sh
git remote add hydra https://git.experiencenet.com/cyborn/rogue.git
git push hydra master
git tag v1.0.0
git push hydra v1.0.0
```

The `v*` tag is the deploy trigger. A plain branch push would build and push
the image only.

### B3. The watcher takes over

Gitea fires the push webhook to hydragitwatcher `POST /api/v1/hooks/git`
(HMAC-verified; a `git ls-remote` poll is the fallback if it is missed). The
watcher then, automatically:

1. Sees the `v*` tag ref, shallow-fetches the tagged SHA into its sync dir,
   reads `.hydrabuild.yaml`.
2. `buildx build --builder hydra --platform linux/amd64,linux/arm64 --push -t
   scaleregistry.experiencenet.com/rogue:v1.0.0 -t :latest .` — amd64 built
   natively on the hcloud daemon, arm64 natively on the Pi daemon.
3. Drives `hydraskin` via the hydracluster exec channel: first launch creates
   the scale from `scaleregistry:rogue:v1.0.0`, attaches the `/data` disk,
   sets the labels, exposes `8080`, starts, health-checks. A redeploy is
   `hydraskin update rogue --tag v1.0.0 --apply`.
4. Sets `user.hydra.domain=rogue.experiencenet.com`, `user.hydra.port=8080`,
   `user.hydra.health_path=/`.
5. Ensures DNS (a no-op verify — the `*.experiencenet.com` wildcard already
   resolves to the router edge).
6. Posts build-notify to hydracluster and AgentPush state, then cleans up.

hydrascalerouter discovers the labelled scale (~30s) and serves it.

---

## Acceptance criteria

The first pipeline test passes when all of these hold:

```sh
# both arches present in the registry
docker buildx imagetools inspect scaleregistry.experiencenet.com/rogue:v1.0.0 \
  | grep -E 'linux/amd64|linux/arm64'

# the scale is live over the router
curl -sI https://rogue.experiencenet.com/            # 200, valid cert
curl -s  https://rogue.experiencenet.com/scores      # top ten renders
```

- The rogue scale is running with all three `user.hydra.*` labels set.
- `rogue.experiencenet.com` serves the game within ~30s of the scale coming up;
  the game is playable over `/ws`.
- The watcher recorded a build-notify and an AgentPush.
- A save written under `/data` survives a redeploy (state persistence).

## Rollback / teardown

```sh
# re-pin the previous image (hydraskin caches it)
hydraskin update rogue --tag <prev-tag> --apply

# tear the test down entirely: delete the scale, then its DNS record if any.
# The provisioned Gitea repo/account can stay or be removed by an admin.
```

## Open items carried from the design

- **First-launch one-shot.** `hydraskin update` reads an existing instance; the
  clean fix is a `hydraskin deploy <scale> --image ... --domain --port
  --health-path --disk` idempotent create-or-update, tracked as a hydraskin PR.
  Until then the watcher emits the ordered create+attach+label+expose+start
  sequence.
- **DNS wildcard.** This runbook assumes `*.experiencenet.com` already resolves
  to the router edge, making "ensure DNS" a verify-only no-op. Confirm the zone
  before the first run.
- **Registry GC.** Per-push image tags grow unbounded; a retention policy is
  out of scope here and flagged for later.
