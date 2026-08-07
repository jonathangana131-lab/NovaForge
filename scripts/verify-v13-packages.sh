#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_DIR="$ROOT_DIR/Packages"
CONFIGURATION="${NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION:-debug}"

case "$CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "error: NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION must be 'debug' or 'release' (got '$CONFIGURATION')" >&2
    exit 64
    ;;
esac

if [[ ! -d "$PACKAGES_DIR" ]]; then
  echo "error: Packages directory is missing: $PACKAGES_DIR" >&2
  exit 2
fi

shopt -s nullglob
package_manifests=("$PACKAGES_DIR"/*/Package.swift)
shopt -u nullglob

if (( ${#package_manifests[@]} == 0 )); then
  echo "error: no top-level Swift packages found under Packages/*/Package.swift" >&2
  exit 2
fi

list_packages() {
  local manifest package_dir
  for manifest in "${package_manifests[@]}"; do
    package_dir="${manifest%/Package.swift}"
    printf '%s\n' "${package_dir#"$ROOT_DIR"/}"
  done
}

case "${1:-}" in
  "")
    ;;
  --list)
    list_packages
    exit 0
    ;;
  *)
    echo "usage: $0 [--list]" >&2
    exit 64
    ;;
esac

printf 'NovaForge Swift package contract gate: %d package(s), configuration=%s\n' \
  "${#package_manifests[@]}" "$CONFIGURATION"

status=0
for manifest in "${package_manifests[@]}"; do
  package_dir="${manifest%/Package.swift}"
  relative_package="${package_dir#"$ROOT_DIR"/}"

  echo "::group::${relative_package} (${CONFIGURATION})"
  if swift test \
    --package-path "$package_dir" \
    --configuration "$CONFIGURATION" \
    -Xswiftc -warnings-as-errors; then
    echo "PASS: ${relative_package} (${CONFIGURATION})"
  else
    echo "::error title=Swift package contract failed::${relative_package} (${CONFIGURATION}) failed"
    status=1
  fi
  echo "::endgroup::"
done

if (( status != 0 )); then
  echo "One or more Swift package contract suites failed." >&2
  exit "$status"
fi

echo "All discovered Swift package contract suites passed (${CONFIGURATION})."
