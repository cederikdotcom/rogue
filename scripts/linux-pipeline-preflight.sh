#!/usr/bin/env bash
#
# linux-pipeline-preflight.sh - preflight for running rogue through the Linux
# container pipeline (issue #508: hydralinuxpipeline + hydrapipelinerunnerlinux).
# See docs/runbooks/linux-pipeline-run.md.
#
# SAFETY: this script mutates NOTHING. It only reads files in the repo, does
# read-only HTTP GETs against service health and (if a read-only token is
# given) the fleet inventory, and read-only DNS resolution. It never pushes,
# never enqueues an op, never builds-and-pushes, never touches a live scale or
# an hcloud server. It asserts the prerequisites the pipeline depends on and
# prints a go/no-go plus the manual operator steps that DO mutate live infra.
# It is safe to run from any clone at any time.
#
# Usage:
#   scripts/linux-pipeline-preflight.sh           assert prerequisites, print go/no-go
#   scripts/linux-pipeline-preflight.sh --build    also dry-run a NATIVE host-arch
#                                                   image build (type=cacheonly, no push)
#   scripts/linux-pipeline-preflight.sh --help
#
# Optional environment (all read-only; unset ones become WARN, not FAIL):
#   HLP_URL                 hydralinuxpipeline base URL
#                           (default https://linuxpipeline.experiencenet.com)
#   HPRL_URL                hydrapipelinerunnerlinux base URL (often internal;
#                           unset skips the runner health probe)
#   CLUSTER_URL             hydracluster base URL
#                           (default https://hydracluster.experiencenet.com)
#   CLUSTER_READONLY_TOKEN  read-only token for GET /api/v1/nodes (fleet read).
#                           Unset skips the native-arm64-capacity probe.
#   REGISTRY                scale registry host
#                           (default scaleregistry.experiencenet.com)
#
set -euo pipefail

# --- expected pipeline constants (must match .hydrabuild.yaml) --------------
EXP_NAME="rogue"
EXP_DOMAIN="rogue.experiencenet.com"
EXP_PORT="8080"
EXP_HEALTH="/"
EXP_ARCH="linux/arm64"          # rogue's production home is the arm64 Pi fleet
EDGE_IP="141.227.136.199"

HLP_URL="${HLP_URL:-https://linuxpipeline.experiencenet.com}"
HPRL_URL="${HPRL_URL:-}"
CLUSTER_URL="${CLUSTER_URL:-https://hydracluster.experiencenet.com}"
CLUSTER_READONLY_TOKEN="${CLUSTER_READONLY_TOKEN:-}"
REGISTRY="${REGISTRY:-scaleregistry.experiencenet.com}"
TEST_TAG="vTEST"

# --- locate the repo root (parent of this script's dir) ---------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HB="$ROOT/.hydrabuild.yaml"
DF="$ROOT/Dockerfile"

DO_BUILD=0
case "${1:-}" in
  --build) DO_BUILD=1 ;;
  -h|--help)
    sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# read a flat "key: value" from .hydrabuild.yaml (grep-based, so we take no
# dependency on a YAML parser). $1 = key, prints the value.
hbval() { grep -E "^[[:space:]]*$1:[[:space:]]*" "$HB" | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*(#.*)?$//"; }

# read-only HTTP GET; prints "STATUS<TAB>BODY". Never sends a mutating verb.
http_get() {
  # $1 url, $2 optional bearer token
  local url="$1" tok="${2:-}"
  if [ -n "$tok" ]; then
    curl -fsS --max-time 8 -H "Authorization: Bearer $tok" -w '\n%{http_code}' "$url" 2>/dev/null || return 1
  else
    curl -fsS --max-time 8 -w '\n%{http_code}' "$url" 2>/dev/null || return 1
  fi
}

hdr "1. Repo files present"
[ -f "$DF" ] && ok "Dockerfile present" || bad "Dockerfile MISSING"
if [ -f "$HB" ]; then
  ok ".hydrabuild.yaml present (declares scale + build intent)"
else
  warn ".hydrabuild.yaml MISSING on this branch; the pipeline reads it from the built commit. It lands with the #492/#508 pipeline branch; ensure the tagged commit carries it."
fi
[ -f "$ROOT/.github/workflows/deploy-image.yml" ] \
  && ok "deploy-image.yml present (legacy CI publish, superseded by the pipeline)" \
  || warn "deploy-image.yml absent (no legacy fallback publish)"

if [ -f "$HB" ]; then
  hdr "2. .hydrabuild.yaml declares the expected scale intent"
  v=$(hbval name);        [ "$v" = "$EXP_NAME" ]   && ok "scale.name = $v"        || bad "scale.name = '$v' (want $EXP_NAME)"
  v=$(hbval domain);      [ "$v" = "$EXP_DOMAIN" ] && ok "scale.domain = $v"      || bad "scale.domain = '$v' (want $EXP_DOMAIN)"
  v=$(hbval port);        [ "$v" = "$EXP_PORT" ]   && ok "scale.port = $v"        || bad "scale.port = '$v' (want $EXP_PORT)"
  v=$(hbval health_path); [ "$v" = "$EXP_HEALTH" ] && ok "scale.health_path = $v" || bad "scale.health_path = '$v' (want $EXP_HEALTH)"
fi

hdr "3. Target architecture: arm64, native (Pi fleet), no QEMU"
if [ ! -f "$HB" ]; then
  warn "cannot verify build.platforms: .hydrabuild.yaml absent on this branch (it arrives with the pipeline commit). arm64 must be declared there."
elif grep -q 'linux/arm64' "$HB"; then
  ok "build.platforms includes linux/arm64 (required: the Pi fleet is arm64)"
  grep -q 'linux/amd64' "$HB" \
    && ok "build.platforms also includes linux/amd64 (hcloud nodes)" \
    || warn "build.platforms lists no linux/amd64; only arm64 nodes can run this image"
else
  bad "linux/arm64 must be a declared build platform in $HB; rogue's production home is arm64"
fi
echo "     NOTE arm64 is built NATIVELY: a Tier 1 arm64 fleet node with headroom,"
echo "          or a Tier 2 on-demand hcloud cax server. arm64 is never emulated."

if [ -f "$DF" ]; then
  hdr "4. Dockerfile honours the scale conventions"
  grep -qE '^EXPOSE[[:space:]]+8080' "$DF" && ok "EXPOSE 8080 (plain HTTP, TLS at the edge)" || bad "must EXPOSE 8080"
  ! grep -qE '^VOLUME' "$DF"                && ok "no VOLUME (Incus OCI runtime cannot mount one)" || bad "must NOT declare a VOLUME"
  grep -q 'HYDRA_AUTO_UPDATE' "$DF"         && ok "HYDRA_AUTO_UPDATE declared" || warn "HYDRA_AUTO_UPDATE convention not declared"
  grep -q 'NO_SHELL_ESCAPE' "$DF"           && ok "NO_SHELL_ESCAPE build flag set (no shell for visitors)" || bad "C game must build with -DNO_SHELL_ESCAPE"
  grep -q '/data' "$DF"                      && ok "state on /data (attached disk device, not baked in)" || warn "state path /data not referenced"
fi

hdr "5. hydralinuxpipeline reachable (read-only health)"
if out=$(http_get "$HLP_URL/api/v1/health"); then
  code=$(printf '%s' "$out" | tail -1)
  if [ "$code" = "200" ]; then
    ok "GET $HLP_URL/api/v1/health -> 200"
    printf '%s' "$out" | head -n -1 | grep -q 'jobs' \
      && ok "health reports job counts (control plane job model is live)" \
      || warn "health returned 200 but no job-count fields seen"
  else
    warn "GET $HLP_URL/api/v1/health -> HTTP $code (service up but unhealthy?)"
  fi
else
  warn "hydralinuxpipeline health unreachable at $HLP_URL (set HLP_URL, or it is not deployed yet)"
fi

hdr "6. hydrapipelinerunnerlinux reachable (read-only health)"
if [ -z "$HPRL_URL" ]; then
  warn "HPRL_URL unset; the runner is often internal-only. Skipping its health probe. Confirm it is deployed with --apply and cluster/registry/hcloud config."
elif out=$(http_get "$HPRL_URL/api/v1/health"); then
  code=$(printf '%s' "$out" | tail -1)
  [ "$code" = "200" ] && ok "GET $HPRL_URL/api/v1/health -> 200" \
                      || warn "GET $HPRL_URL/api/v1/health -> HTTP $code"
else
  warn "runner health unreachable at $HPRL_URL"
fi

hdr "7. hydracluster reachable + native arm64 builder capacity"
if out=$(http_get "$CLUSTER_URL/api/v1/health"); then
  ok "hydracluster reachable at $CLUSTER_URL"
else
  warn "hydracluster health unreachable at $CLUSTER_URL (set CLUSTER_URL)"
fi
if [ -z "$CLUSTER_READONLY_TOKEN" ]; then
  warn "CLUSTER_READONLY_TOKEN unset; cannot read the fleet inventory to confirm an online arm64 node has headroom. Tier 2 (hcloud cax) is the fallback if none does."
elif out=$(http_get "$CLUSTER_URL/api/v1/nodes" "$CLUSTER_READONLY_TOKEN"); then
  body=$(printf '%s' "$out" | head -n -1)
  # count online arm64 nodes without unmarshalling the full shape
  arm=$(printf '%s' "$body" | grep -o '"arch":"[^"]*"' | grep -ci 'arm64' || true)
  if [ "${arm:-0}" -gt 0 ]; then
    ok "fleet inventory readable; $arm node(s) report arm64 (Tier 1 candidates; runner still applies the OOM guardrail)"
  else
    warn "no arm64 node found in the fleet inventory; arm64 builds would need Tier 2 (hcloud cax)"
  fi
else
  warn "could not read $CLUSTER_URL/api/v1/nodes with the given read-only token"
fi

hdr "8. scale registry reachable (read-only)"
if curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' "https://$REGISTRY/v2/" 2>/dev/null | grep -qE '^(200|401)$'; then
  ok "https://$REGISTRY/v2/ reachable (push destination for the built image)"
else
  warn "https://$REGISTRY/v2/ not reachable here (auth or network); confirm the runner can reach it"
fi

hdr "9. DNS is read-only verified (explicit A record -> the edge; no wildcard)"
if command -v getent >/dev/null 2>&1 && getent hosts "$EXP_DOMAIN" 2>/dev/null | grep -q "$EDGE_IP"; then
  ok "$EXP_DOMAIN resolves to $EDGE_IP (A record present)"
elif command -v host >/dev/null 2>&1 && host "$EXP_DOMAIN" 2>/dev/null | grep -q "$EDGE_IP"; then
  ok "$EXP_DOMAIN resolves to $EDGE_IP (A record present)"
else
  warn "$EXP_DOMAIN did not resolve to $EDGE_IP here; the A record must exist BEFORE routing (else Traefik ACME hits NXDOMAIN). There is no wildcard."
fi

if [ "$DO_BUILD" = "1" ]; then
  hdr "10. Dry-run a NATIVE host-arch build (type=cacheonly, NOTHING pushed)"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not available; skipping the local build dry-run"
  elif ! docker buildx version >/dev/null 2>&1; then
    warn "docker buildx not available; skipping the local build dry-run"
  else
    echo "  running (no --platform, native host arch, no push):"
    echo "    docker buildx build -t $REGISTRY/$EXP_NAME:$TEST_TAG --output type=cacheonly $ROOT"
    if docker buildx build -t "$REGISTRY/$EXP_NAME:$TEST_TAG" --output type=cacheonly "$ROOT"; then
      ok "native host-arch build succeeded (nothing pushed)"
    else
      bad "host-arch build FAILED"
    fi
  fi
else
  hdr "10. Local build dry-run skipped (pass --build to run a cacheonly native build)"
fi

# --- go / no-go summary -----------------------------------------------------
hdr "Summary"
printf '  %d passed, %d warnings, %d failed\n' "$PASS" "$WARN" "$FAIL"

hdr "SECRETS AN OPERATOR PLACES (never committed, never printed here)"
cat <<'EOF'
  - scaleregistry push token (user "hydra"): in hydrapipelinerunnerlinux config
    as scaleregistry.token; provisioned INTO the builder via password-stdin.
  - cluster op-token (scoped, cannot exec): both services, to enqueue ScaleOps.
  - cluster read-only token: hydrapipelinerunnerlinux, to read the fleet.
  - hcloud token: hydrapipelinerunnerlinux, Tier 2 only.
  - pipeline admin_token + runner.token: the control->manager and watcher->
    control auth. None of these live in this repo.
EOF

hdr "GO / NO-GO - manual operator steps (these MUTATE live infra; run in order)"
cat <<EOF
  [ ] P0  hydracluster runs the #497 generic op-relay (scoped op-token; /ops
          only, never /exec). Both services mutate ONLY through it.
  [ ] P0  hydralinuxpipeline deployed at $HLP_URL with admin_token, runner.url,
          runner.token, cluster.url, cluster.op_token, and --apply.
  [ ] P0  hydrapipelinerunnerlinux deployed with cluster read-only + op tokens,
          scaleregistry creds, builder.image, hcloud.token, and --apply.
  [ ] P0  hydra-builder image present in $REGISTRY for arm64 (and amd64).
  [ ] P0  native arm64 capacity: an online arm64 fleet node with headroom, or
          hcloud budget for a cax server. The runner refuses rather than starve
          a production node (Pi OOM guardrail).
  [ ] P0  hydragitwatcher watching cederikdotcom/rogue, emitting build-notify
          { watch_name, scm_type, scm_ref, build_url } to $HLP_URL on a v* tag.
  [ ] P0  A record $EXP_DOMAIN -> $EDGE_IP exists and resolves globally.
  [ ] R1  git tag v1.0.0 && git push origin v1.0.0
  [ ] R2  watcher POSTs build-notify; job appears queued at $HLP_URL/admin
  [ ] R3  runner places a native arm64 builder (Tier 1 scale, or Tier 2 cax),
          buildctl builds + pushes $REGISTRY/$EXP_NAME:v1.0.0, returns digest;
          job -> pushed; builder torn down (always)
  [ ] R4  pipeline enqueues ScaleOp launch/update on the target node with
          user.hydra.{image_digest,health_path,autoupdate} labels; job -> live
  [ ] ACC docker buildx imagetools inspect $REGISTRY/$EXP_NAME:v1.0.0  (arm64 present)
  [ ] ACC curl -sI https://$EXP_DOMAIN/          (200, valid cert)
  [ ] ACC curl -s  https://$EXP_DOMAIN/scores    (top ten renders)
  [ ] ACC labels user.hydra.domain=$EXP_DOMAIN / port=$EXP_PORT / health_path=$EXP_HEALTH
  [ ] ACC a save under /data survives a redeploy
EOF

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mNO-GO\033[0m: %d preflight check(s) failed - fix before the live run.\n' "$FAIL"
  exit 1
fi
printf '\n\033[32mGO\033[0m: preflight green. Proceed with the manual operator steps above.\n'
