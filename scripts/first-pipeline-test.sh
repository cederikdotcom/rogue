#!/usr/bin/env bash
#
# first-pipeline-test.sh — preflight for rogue's first git-push-to-deploy run
# (issue #492). See docs/runbooks/first-pipeline-test.md.
#
# SAFETY: this script mutates NOTHING in production. It only reads files in the
# repo, dry-runs the build (never --push), and does read-only DNS resolution.
# It asserts the prerequisites the pipeline depends on, then prints the manual
# go/no-go operator steps. It is safe to run from any clone at any time.
#
# Usage:
#   scripts/first-pipeline-test.sh            assert prerequisites, print go/no-go
#   scripts/first-pipeline-test.sh --build    also dry-run the multi-arch build
#   scripts/first-pipeline-test.sh --help
#
set -euo pipefail

# --- expected pipeline constants (must match .hydrabuild.yaml) --------------
EXP_NAME="rogue"
EXP_DOMAIN="rogue.experiencenet.com"
EXP_PORT="8080"
EXP_HEALTH="/"
REGISTRY="scaleregistry.experiencenet.com"
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
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# read a flat "key: value" from a section of .hydrabuild.yaml (grep-based, so
# we take no dependency on a YAML parser). $1 = key, prints the value.
hbval() { grep -E "^[[:space:]]*$1:[[:space:]]*" "$HB" | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*(#.*)?$//"; }

hdr "1. Repo files present"
[ -f "$HB" ] && ok ".hydrabuild.yaml present" || bad ".hydrabuild.yaml MISSING"
[ -f "$DF" ] && ok "Dockerfile present"       || bad "Dockerfile MISSING"
[ -f "$ROOT/.github/workflows/deploy-image.yml" ] \
  && ok "deploy-image.yml present (fallback image publish)" \
  || warn "deploy-image.yml missing (fallback publish unavailable)"

if [ -f "$HB" ]; then
  hdr "2. .hydrabuild.yaml declares the expected scale intent"
  v=$(hbval name);        [ "$v" = "$EXP_NAME" ]   && ok "scale.name = $v"          || bad "scale.name = '$v' (want $EXP_NAME)"
  v=$(hbval domain);      [ "$v" = "$EXP_DOMAIN" ] && ok "scale.domain = $v"        || bad "scale.domain = '$v' (want $EXP_DOMAIN)"
  v=$(hbval port);        [ "$v" = "$EXP_PORT" ]   && ok "scale.port = $v"          || bad "scale.port = '$v' (want $EXP_PORT)"
  v=$(hbval health_path); [ "$v" = "$EXP_HEALTH" ] && ok "scale.health_path = $v"   || bad "scale.health_path = '$v' (want $EXP_HEALTH)"
  grep -q 'linux/amd64' "$HB" && grep -q 'linux/arm64' "$HB" \
    && ok "build.platforms = linux/amd64 + linux/arm64" \
    || bad "build.platforms must list linux/amd64 AND linux/arm64"
fi

if [ -f "$DF" ]; then
  hdr "3. Dockerfile honours the scale conventions"
  grep -qE '^EXPOSE[[:space:]]+8080' "$DF"        && ok "EXPOSE 8080 (plain HTTP, TLS at edge)" || bad "must EXPOSE 8080"
  ! grep -qE '^VOLUME' "$DF"                       && ok "no VOLUME (Incus OCI can't mount one)" || bad "must NOT declare a VOLUME"
  grep -q 'HYDRA_AUTO_UPDATE' "$DF"               && ok "HYDRA_AUTO_UPDATE declared"            || warn "HYDRA_AUTO_UPDATE convention not declared"
  grep -q 'NO_SHELL_ESCAPE' "$DF"                 && ok "NO_SHELL_ESCAPE build flag set"        || bad "C game must build with -DNO_SHELL_ESCAPE"
  grep -q '/data' "$DF"                           && ok "state on /data (attached disk device)" || warn "state path /data not referenced"
fi

hdr "4. DNS is read-only verified (wildcard should cover the host)"
if command -v getent >/dev/null 2>&1 && getent hosts "$EXP_DOMAIN" >/dev/null 2>&1; then
  ok "$EXP_DOMAIN resolves (wildcard/live) — ensure-DNS is a no-op"
elif command -v host >/dev/null 2>&1 && host "$EXP_DOMAIN" >/dev/null 2>&1; then
  ok "$EXP_DOMAIN resolves (wildcard/live) — ensure-DNS is a no-op"
else
  warn "$EXP_DOMAIN did not resolve here; confirm the *.experiencenet.com wildcard before the live run"
fi

if [ "$DO_BUILD" = "1" ]; then
  hdr "5. Dry-run the multi-arch build (NO --push, output cacheonly)"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not available; skipping build dry-run"
  elif ! docker buildx version >/dev/null 2>&1; then
    warn "docker buildx not available; skipping build dry-run"
  else
    echo "  running: docker buildx build --platform linux/amd64,linux/arm64 \\"
    echo "             -t $REGISTRY/$EXP_NAME:$TEST_TAG --output type=cacheonly $ROOT"
    if docker buildx build --platform linux/amd64,linux/arm64 \
         -t "$REGISTRY/$EXP_NAME:$TEST_TAG" --output type=cacheonly "$ROOT"; then
      ok "multi-arch build succeeded (nothing pushed)"
    else
      bad "multi-arch build FAILED"
    fi
  fi
else
  hdr "5. Build dry-run skipped (pass --build to run it)"
fi

# --- go / no-go summary -----------------------------------------------------
hdr "Summary"
printf '  %d passed, %d warnings, %d failed\n' "$PASS" "$WARN" "$FAIL"

hdr "THE ONE HUMAN-PROVIDED SECRET"
cat <<'EOF'
  The scale-registry push token (registry user "hydra" for
  scaleregistry.experiencenet.com) is the single value a human must place by
  hand. In the pipeline it lives in hydragitwatcher's config as
  registry.token, and the watcher propagates it to the two buildkitd builders.
  It is NOT in this repo and must never be committed or printed.
  (The old deploy-image.yml still uses the repo secret SCALE_REGISTRY_TOKEN as
  a fallback; the pipeline's authoritative copy is the watcher's.)
EOF

hdr "GO / NO-GO — manual operator steps (mutate live infra; run in order)"
cat <<EOF
  [ ] B0  hydragitprovision up (systemd, localhost) with the Gitea admin token
  [ ] B0  two buildkitd builder scales up and mesh-reachable (tcp://<mesh>:1234)
  [ ] B0  hydragitwatcher deployed as a scale, watching cyborn/rogue (ref v*),
          with registry.token and its hydracluster admin token set
  [ ] B1  creator signs in at hydramancer /deploy and requests repo:
            { "kind":"git", "org_slug":"cyborn", "name":"$EXP_NAME" }
          -> save the one-time temp_password from the response
  [ ] B2  git push <clone-url> master && git tag v1.0.0 && git push <clone-url> v1.0.0
  [ ] B3  watcher builds multi-arch, pushes $REGISTRY/$EXP_NAME:v1.0.0,
          launches/updates the scale, sets labels, verifies DNS
  [ ] ACC docker buildx imagetools inspect $REGISTRY/$EXP_NAME:v1.0.0  (amd64 + arm64)
  [ ] ACC curl -sI https://$EXP_DOMAIN/            (200, valid cert)
  [ ] ACC curl -s  https://$EXP_DOMAIN/scores      (top ten renders)
  [ ] ACC labels user.hydra.domain=$EXP_DOMAIN / port=$EXP_PORT / health_path=$EXP_HEALTH
  [ ] ACC a save under /data survives a redeploy
EOF

if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mNO-GO\033[0m: %d preflight check(s) failed — fix before the live run.\n' "$FAIL"
  exit 1
fi
printf '\n\033[32mGO\033[0m: preflight green. Proceed with the manual operator steps above.\n'
