#!/bin/zsh
set -euo pipefail

# Export and AOT-compile the exact Core AI Qwen recipe represented in
# LocalModelCatalog.v2.json. This intentionally refuses unsupported hosts.

readonly COREAI_REPOSITORY="https://github.com/apple/coreai-models.git"
readonly COREAI_REVISION="f43b6da728c6af5af15db345ffb2d8402d27013b"
readonly COREAI_MODEL="Qwen/Qwen3-0.6B"
readonly CONTEXT_LENGTH="1024"
readonly OUTPUT_NAME="Qwen3-0.6B-iOS27"
readonly WORK_DIRECTORY="${LOCAL_AI_COREAI_WORK_DIR:-${PWD}/.build/local-ai-coreai}"
readonly SOURCE_DIRECTORY="${WORK_DIRECTORY}/coreai-models"
readonly COMPILED_DIRECTORY="${WORK_DIRECTORY}/compiled"
readonly REPO_ROOT="${0:A:h:h}"
readonly TIMEOUT_RUNNER="${REPO_ROOT}/scripts/codex-timeout-runner.pl"

[[ -x "${TIMEOUT_RUNNER}" ]] || {
  print -u2 "Timeout runner is unavailable: ${TIMEOUT_RUNNER}"
  exit 2
}

if [[ "$(uname -m)" != "arm64" ]]; then
  print -u2 "Core AI export requires an Apple Silicon Mac; this host is $(uname -m)."
  exit 2
fi

readonly XCODE_VERSION_LOG="${WORK_DIRECTORY}/xcode-version.log"
mkdir -p "${WORK_DIRECTORY}"
TIMEOUT_RUNNER_LABEL="coreai-xcode-version" \
  "${TIMEOUT_RUNNER}" 60 "${XCODE_VERSION_LOG}" xcodebuild -version
readonly XCODE_VERSION="$(awk 'NR == 1 { print $2 }' "${XCODE_VERSION_LOG}")"
if [[ "${XCODE_VERSION%%.*}" -lt 27 ]]; then
  print -u2 "Core AI export requires Xcode 27 or later; selected Xcode is ${XCODE_VERSION}."
  exit 2
fi

if ! command -v uv >/dev/null 2>&1; then
  print -u2 "Install uv first (for example: brew install uv)."
  exit 2
fi

if ! TIMEOUT_RUNNER_LABEL="coreai-toolchain-probe" \
  "${TIMEOUT_RUNNER}" 60 "${WORK_DIRECTORY}/coreai-toolchain-probe.log" \
  xcrun --find coreai-build >/dev/null 2>&1; then
  print -u2 "coreai-build is unavailable. Install the Xcode 27 Metal Toolchain component."
  exit 2
fi

mkdir -p "${WORK_DIRECTORY}" "${COMPILED_DIRECTORY}"
if [[ ! -d "${SOURCE_DIRECTORY}/.git" ]]; then
  TIMEOUT_RUNNER_LABEL="coreai-git-clone" \
    "${TIMEOUT_RUNNER}" 600 "${WORK_DIRECTORY}/git-clone.log" \
    git clone --filter=blob:none "${COREAI_REPOSITORY}" "${SOURCE_DIRECTORY}"
fi

TIMEOUT_RUNNER_LABEL="coreai-git-fetch" \
  "${TIMEOUT_RUNNER}" 600 "${WORK_DIRECTORY}/git-fetch.log" \
  git -C "${SOURCE_DIRECTORY}" fetch --depth 1 origin "${COREAI_REVISION}"
TIMEOUT_RUNNER_LABEL="coreai-git-checkout" \
  "${TIMEOUT_RUNNER}" 120 "${WORK_DIRECTORY}/git-checkout.log" \
  git -C "${SOURCE_DIRECTORY}" checkout --detach "${COREAI_REVISION}"
if [[ "$(git -C "${SOURCE_DIRECTORY}" rev-parse HEAD)" != "${COREAI_REVISION}" ]]; then
  print -u2 "Pinned Core AI source revision did not resolve exactly."
  exit 3
fi

cd "${SOURCE_DIRECTORY}"
TIMEOUT_RUNNER_LABEL="coreai-export" \
  "${TIMEOUT_RUNNER}" 1800 "${WORK_DIRECTORY}/coreai-export.log" \
  uv run coreai.llm.export "${COREAI_MODEL}" \
    --platform iOS \
    --max-context-length "${CONTEXT_LENGTH}" \
    --output-name "${OUTPUT_NAME}"

readonly EXPORTED_MODEL="$(find "${SOURCE_DIRECTORY}" -type f -name "${OUTPUT_NAME}.aimodel" -print -quit)"
if [[ -z "${EXPORTED_MODEL}" ]]; then
  print -u2 "Export completed without the expected ${OUTPUT_NAME}.aimodel asset."
  exit 4
fi

TIMEOUT_RUNNER_LABEL="coreai-compile" \
  "${TIMEOUT_RUNNER}" 1800 "${WORK_DIRECTORY}/coreai-compile.log" \
  xcrun coreai-build compile "${EXPORTED_MODEL}" \
    --platform iOS \
    --min-deployment-version 27.0 \
    --output "${COMPILED_DIRECTORY}"

print "Core AI source: ${COREAI_REVISION}"
print "Exported model: ${EXPORTED_MODEL}"
print "Compiled assets: ${COMPILED_DIRECTORY}"
find "${COMPILED_DIRECTORY}" -type f -print0 | xargs -0 shasum -a 256
print "Do not ship these files until metadata, tokenizer resources, licenses, device architecture, and the catalog checksum are reviewed and pinned."
