#!/usr/bin/env bash
# Generates the kubeconform JSON schemas in deploy/k8s/schemas for the custom resources of the gcp
# overlays (never edit them by hand):
#   gateway.networking.k8s.io  Gateway and HTTPRoute, converted by scripts/crd-to-jsonschema.mjs
#                              from the CRDs of the official Gateway API release asset
#                              standard-install.yaml, at the version that GKE serves
#   networking.gke.io          HealthCheckPolicy and GCPBackendPolicy: GKE installs these CRDs
#                              itself and Google publishes no CRD file, so the schemas are copied
#                              as they are from a pinned commit of the datreeio/CRDs-catalog
# source.env records the URL, version and SHA-256 of every input. Downloads are HTTPS-only and
# refused when their SHA-256 differs; no Docker and no cluster needed.
# Usage:
#   scripts/update-crd-schemas.sh --check
#       downloads the inputs of source.env, regenerates into a temporary dir and compares with the
#       committed files (harness check crd-schemas)
#   scripts/update-crd-schemas.sh <gateway-api-version> <crds-catalog-commit>
#       pins other inputs (e.g. v1.5.0 f3e4382095909ac60000da025f323ba44d4c738a): the Gateway API
#       asset must match the SHA-256 digest that GitHub records for it; rewrites source.env and the
#       schemas
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SCHEMA_DIR="$REPO_ROOT/deploy/k8s/schemas"
SOURCE_FILE="$SCHEMA_DIR/source.env"
GATEWAY_API_REPO=kubernetes-sigs/gateway-api
GATEWAY_API_ASSET=standard-install.yaml
# CRDs of the bundle for the kinds the manifests use.
GATEWAY_API_CRDS=(gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io)
CRDS_CATALOG_REPO=datreeio/CRDs-catalog
# Schemas copied from the catalog: "<prefix of the source.env keys> <path in the catalog and here>".
CATALOG_FILES=(
  "HEALTHCHECKPOLICY networking.gke.io/healthcheckpolicy_v1.json"
  "GCPBACKENDPOLICY networking.gke.io/gcpbackendpolicy_v1.json"
)

WORK_DIR=""
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

usage() {
  echo "usage: $0 --check | <gateway-api-version> <crds-catalog-commit>" >&2
  exit 2
}

gateway_api_url() {
  printf 'https://github.com/%s/releases/download/%s/%s' "$GATEWAY_API_REPO" "$1" "$GATEWAY_API_ASSET"
}

catalog_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/%s' "$CRDS_CATALOG_REPO" "$1" "$2"
}

# fetch URL OUT -> HTTPS-only download (redirects to HTTPS only) with retries; fails on HTTP errors.
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$2" "$1" || die "download failed: $1"
}

# verify FILE SHA256 -> refuses a download whose SHA-256 differs from the pinned one.
verify() {
  local got
  got="$(sha256_of "$1")"
  [[ "$got" == "$2" ]] || die "SHA-256 mismatch for $(basename "$1"): expected $2, got $got. Refusing the download."
}

# source_value KEY -> value of KEY in source.env; fails when it is missing.
source_value() {
  local value
  value="$(env_file_value "$SOURCE_FILE" "$1")"
  [[ -n "$value" ]] || die "$SOURCE_FILE: $1 is missing"
  printf '%s' "$value"
}

# generate BUNDLE CATALOG_DIR OUT_DIR -> every schema into OUT_DIR; prints one path per line.
generate() {
  local bundle=$1 catalog=$2 out=$3 crd entry path
  local -a only=()
  for crd in "${GATEWAY_API_CRDS[@]}"; do
    only+=(--crd "$crd")
  done
  mkdir -p "$out"
  node "$REPO_ROOT/scripts/crd-to-jsonschema.mjs" "${only[@]}" "$out" "$bundle"
  for entry in "${CATALOG_FILES[@]}"; do
    path=${entry#* }
    mkdir -p "$out/$(dirname "$path")"
    cp "$catalog/$path" "$out/$path"
    printf '%s\n' "$path"
  done
}

# generated_files DIR -> the schema files under DIR, relative and sorted.
generated_files() {
  (cd "$1" && find . -type f -name '*.json' | sed 's|^\./||' | sort)
}

check() {
  local version commit url sha entry key path catalog="$WORK_DIR/catalog"
  require_cmd curl node
  [[ -f "$SOURCE_FILE" ]] || die "missing $SOURCE_FILE"
  version="$(source_value GATEWAY_BUNDLE_VERSION)"
  commit="$(source_value CRDS_CATALOG_COMMIT)"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$SOURCE_FILE: GATEWAY_BUNDLE_VERSION must look like v1.5.0"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "$SOURCE_FILE: CRDS_CATALOG_COMMIT must be a 40-character commit SHA"
  url="$(source_value GATEWAY_BUNDLE_URL)"
  [[ "$url" == "$(gateway_api_url "$version")" ]] || die "$SOURCE_FILE: GATEWAY_BUNDLE_URL must be $(gateway_api_url "$version")"
  sha="$(source_value GATEWAY_BUNDLE_SHA256)"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$SOURCE_FILE: GATEWAY_BUNDLE_SHA256 must be 64 lowercase hex characters"
  log "Gateway API $version: $url"
  fetch "$url" "$WORK_DIR/$GATEWAY_API_ASSET"
  verify "$WORK_DIR/$GATEWAY_API_ASSET" "$sha"
  for entry in "${CATALOG_FILES[@]}"; do
    key=${entry%% *}
    path=${entry#* }
    url="$(source_value "${key}_URL")"
    [[ "$url" == "$(catalog_url "$commit" "$path")" ]] || die "$SOURCE_FILE: ${key}_URL must be $(catalog_url "$commit" "$path")"
    sha="$(source_value "${key}_SHA256")"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$SOURCE_FILE: ${key}_SHA256 must be 64 lowercase hex characters"
    log "catalog $path: $url"
    mkdir -p "$catalog/$(dirname "$path")"
    fetch "$url" "$catalog/$path"
    verify "$catalog/$path" "$sha"
  done
  generate "$WORK_DIR/$GATEWAY_API_ASSET" "$catalog" "$WORK_DIR/generated" >"$WORK_DIR/generated.list"
  if [[ "$(generated_files "$WORK_DIR/generated")" != "$(generated_files "$SCHEMA_DIR")" ]]; then
    diff <(generated_files "$WORK_DIR/generated") <(generated_files "$SCHEMA_DIR") >&2 || :
    die "deploy/k8s/schemas holds other files than the generator writes (run scripts/update-crd-schemas.sh $version $commit)"
  fi
  if ! diff -r -x source.env "$WORK_DIR/generated" "$SCHEMA_DIR" >"$WORK_DIR/diff.txt"; then
    head -n 40 "$WORK_DIR/diff.txt" >&2
    die "deploy/k8s/schemas differs from the generator output (never edit it by hand; run scripts/update-crd-schemas.sh $version $commit)"
  fi
  printf 'SUMMARY: %s schemas identical to their pinned inputs (Gateway API %s, datreeio/CRDs-catalog %s): %s\n' \
    "$(wc -l <"$WORK_DIR/generated.list" | tr -d ' ')" "$version" "${commit:0:7}" \
    "$(tr '\n' ' ' <"$WORK_DIR/generated.list" | sed 's/ $//')"
}

# write_source VERSION COMMIT GATEWAY_SHA256 CATALOG_DIR -> rewrites source.env (atomically).
write_source() {
  local version=$1 commit=$2 gateway_sha=$3 catalog=$4 entry key path tmp
  tmp="$(mktemp "$SCHEMA_DIR/.source.env.XXXXXX")"
  {
    echo '# Inputs of the generated JSON schemas in this directory (scripts/update-crd-schemas.sh; never'
    echo "# edit the .json files by hand), pinned on $(date -u +%F)."
    echo '# Gateway API: keep the version that GKE serves on the tx03v2 cluster (GKE doc "GatewayClass'
    echo '# capabilities"), standard channel; the SHA-256 is the digest GitHub records for the asset.'
    echo '# networking.gke.io: GKE installs these CRDs itself and publishes no CRD file; the schemas'
    echo '# are copied from a pinned commit of the datreeio/CRDs-catalog.'
    echo "GATEWAY_BUNDLE_VERSION=$version"
    echo "GATEWAY_BUNDLE_URL=$(gateway_api_url "$version")"
    echo "GATEWAY_BUNDLE_SHA256=$gateway_sha"
    echo "CRDS_CATALOG_COMMIT=$commit"
    for entry in "${CATALOG_FILES[@]}"; do
      key=${entry%% *}
      path=${entry#* }
      echo "${key}_URL=$(catalog_url "$commit" "$path")"
      echo "${key}_SHA256=$(sha256_of "$catalog/$path")"
    done
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SOURCE_FILE"
}

update() {
  local version=$1 commit=$2 digest entry path catalog="$WORK_DIR/catalog"
  require_cmd curl node
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the Gateway API version must look like v1.5.0 (got '$version')"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "the catalog commit must be a full 40-character SHA (got '$commit')"
  # GitHub records the SHA-256 digest of every release asset: the download must match it.
  fetch "https://api.github.com/repos/$GATEWAY_API_REPO/releases/tags/$version" "$WORK_DIR/release.json"
  digest="$(node -e '
    const release = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const asset = (release.assets ?? []).find((a) => a.name === process.argv[2]);
    console.log(asset?.digest ?? "");
  ' "$WORK_DIR/release.json" "$GATEWAY_API_ASSET")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "GitHub records no SHA-256 digest for $GATEWAY_API_ASSET of $version"
  fetch "$(gateway_api_url "$version")" "$WORK_DIR/$GATEWAY_API_ASSET"
  verify "$WORK_DIR/$GATEWAY_API_ASSET" "${digest#sha256:}"
  for entry in "${CATALOG_FILES[@]}"; do
    path=${entry#* }
    mkdir -p "$catalog/$(dirname "$path")"
    fetch "$(catalog_url "$commit" "$path")" "$catalog/$path"
  done
  generate "$WORK_DIR/$GATEWAY_API_ASSET" "$catalog" "$WORK_DIR/generated" >/dev/null
  write_source "$version" "$commit" "${digest#sha256:}" "$catalog"
  find "$SCHEMA_DIR" -type f -name '*.json' -delete
  find "$SCHEMA_DIR" -mindepth 1 -type d -empty -delete
  cp -R "$WORK_DIR/generated/." "$SCHEMA_DIR/"
  log "updated deploy/k8s/schemas to Gateway API $version and datreeio/CRDs-catalog ${commit:0:7}; next:"
  log "HARNESS_STRICT=1 make verify, and the calendar in docs/MAINTENANCE.md (the version GKE serves)."
}

main() {
  case "$#:${1:-}" in
    1:--check) ;;
    2:-*) usage ;;
    2:*) ;;
    *) usage ;;
  esac
  WORK_DIR="$(mktemp -d)"
  if (($# == 1)); then
    check
  else
    update "$1" "$2"
  fi
}

main "$@"
