#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION:-debug}"
export LC_ALL=C

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "error: NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION must be 'debug' or 'release' (got '$CONFIGURATION')" >&2
    exit 64
    ;;
esac

if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: Swift package contract gate requires a Git checkout: $ROOT_DIR" >&2
  exit 2
fi

package_manifests=()
while IFS= read -r tracked_path; do
  case "$tracked_path" in
    Package.swift|*/Package.swift)
      manifest="$ROOT_DIR/$tracked_path"
      if [[ ! -f "$manifest" ]]; then
        echo "error: tracked Swift package manifest is missing from the working tree: $tracked_path" >&2
        exit 2
      fi
      package_manifests+=("$manifest")
      ;;
  esac
done < <(git -C "$ROOT_DIR" ls-files)

if (( ${#package_manifests[@]} == 0 )); then
  echo "error: no tracked Swift package manifests found" >&2
  exit 2
fi

list_packages() {
  local manifest package_dir
  for manifest in "${package_manifests[@]}"; do
    package_dir="${manifest%/Package.swift}"
    if [[ "$package_dir" == "$ROOT_DIR" ]]; then
      printf '.\n'
    else
      printf '%s\n' "${package_dir#"$ROOT_DIR"/}"
    fi
  done
}

case "${1:-}" in
  "") ;;
  --list)
    list_packages
    exit 0
    ;;
  *)
    echo "usage: $0 [--list]" >&2
    exit 64
    ;;
esac

printf 'NovaForge Swift package contract gate: %d tracked package(s), configuration=%s\n' \
  "${#package_manifests[@]}" "$CONFIGURATION"

status=0
for manifest in "${package_manifests[@]}"; do
  package_dir="${manifest%/Package.swift}"
  if [[ "$package_dir" == "$ROOT_DIR" ]]; then
    relative_package="."
  else
    relative_package="${package_dir#"$ROOT_DIR"/}"
  fi

  echo "::group::${relative_package} (${CONFIGURATION})"

  if ! package_description="$(swift package --package-path "$package_dir" dump-package)"; then
    echo "::error title=Swift package manifest failed::${relative_package} (${CONFIGURATION}) could not be loaded"
    status=1
    echo "::endgroup::"
    continue
  fi

  if grep -Eq '"type"[[:space:]]*:[[:space:]]*"test"' <<<"$package_description"; then
    action="test"
    echo "Contract action: swift test"
  else
    action="build"
    echo "Contract action: swift build (no test target declared)"
  fi

  if swift "$action" \
    --package-path "$package_dir" \
    --configuration "$CONFIGURATION" \
    -Xswiftc -warnings-as-errors; then
    echo "PASS: ${relative_package} (${CONFIGURATION}; ${action})"
  else
    echo "::error title=Swift package contract failed::${relative_package} (${CONFIGURATION}; ${action}) failed"
    status=1
  fi
  echo "::endgroup::"
done

if (( status != 0 )); then
  echo "One or more tracked Swift package contracts failed." >&2
  exit "$status"
fi

echo "All tracked Swift package contracts passed (${CONFIGURATION})."
