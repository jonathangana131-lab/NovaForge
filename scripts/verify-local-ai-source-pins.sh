#!/bin/zsh
set -euo pipefail

# Re-check the catalog against immutable upstream metadata without downloading
# multi-gigabyte artifacts. The ordinary catalog validator remains offline and
# deterministic; this networked audit is for release preparation.

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly CATALOG_PATH="${1:-${REPOSITORY_ROOT}/AgentPad/Resources/LocalModelCatalog.v2.json}"

for command_name in curl jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    print -u2 "Missing required command: ${command_name}"
    exit 2
  fi
done

"${REPOSITORY_ROOT}/scripts/validate-local-ai-catalog.sh" "${CATALOG_PATH}"

verify_hugging_face_artifact() {
  local model_json="$1"
  local download_url repository revision filename expected_bytes expected_sha expected_date tree_json
  download_url="$(jq -r '.downloadURL' <<<"${model_json}")"
  repository="$(sed -E 's#^https://huggingface\.co/([^/]+/[^/]+)/resolve/.*#\1#' <<<"${download_url}")"
  revision="$(jq -r '.immutableRevision' <<<"${model_json}")"
  filename="$(jq -r '.filename' <<<"${model_json}")"
  expected_bytes="$(jq -r '.expectedBytes' <<<"${model_json}")"
  expected_sha="$(jq -r '.expectedSHA256' <<<"${model_json}")"
  expected_date="$(jq -r '.releaseDateISO8601' <<<"${model_json}")"

  if [[ "${repository}" == "${download_url}" ]]; then
    print -u2 "Could not parse Hugging Face repository from ${download_url}"
    exit 3
  fi
  tree_json="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 45 \
    "https://huggingface.co/api/models/${repository}/tree/${revision}?recursive=true&expand=true")"
  if ! jq -e \
    --arg filename "${filename}" \
    --arg sha "${expected_sha}" \
    --arg release_date "${expected_date}" \
    --argjson bytes "${expected_bytes}" \
    '.[] | select(.path == $filename) |
      .size == $bytes and
      .lfs.oid == $sha and
      (.lastCommit.date | startswith($release_date))' \
    <<<"${tree_json}" >/dev/null; then
    print -u2 "Upstream artifact metadata changed or is unavailable: ${repository}/${filename}@${revision}"
    exit 4
  fi
  print "Verified ${repository}/${filename}@${revision}"
}

verify_revision_date() {
  local repository="$1"
  local revision="$2"
  local expected_date="$3"
  local metadata observed_sha observed_date
  metadata="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 45 \
    "https://huggingface.co/api/models/${repository}/revision/${revision}")"
  observed_sha="$(jq -r '.sha // empty' <<<"${metadata}")"
  observed_date="$(jq -r '.lastModified // empty' <<<"${metadata}" | cut -c 1-10)"
  if [[ "${observed_sha}" != "${revision}" || "${observed_date}" != "${expected_date}" ]]; then
    print -u2 "Pinned revision/date mismatch: ${repository}@${revision} expected ${expected_date}, observed ${observed_sha:-missing} ${observed_date:-missing}"
    exit 5
  fi
  print "Verified ${repository}@${revision} (${expected_date})"
}

while IFS= read -r model_json; do
  verify_hugging_face_artifact "${model_json}"
done < <(jq -c '.models[] | select(.artifactKind == "downloadable")' "${CATALOG_PATH}")

readonly POWER_REVISION="$(jq -r '.models[] | select(.engineType == "companion") | .immutableRevision' "${CATALOG_PATH}")"
readonly POWER_DATE="$(jq -r '.models[] | select(.engineType == "companion") | .releaseDateISO8601' "${CATALOG_PATH}")"
verify_revision_date "Qwen/Qwen3.8-27B" "${POWER_REVISION}" "${POWER_DATE}"

readonly COREAI_REVISION="$(jq -r '.models[] | select(.engineType == "coreAI") | .immutableRevision' "${CATALOG_PATH}")"
readonly COREAI_DATE="$(jq -r '.models[] | select(.engineType == "coreAI") | .releaseDateISO8601' "${CATALOG_PATH}")"
readonly COREAI_METADATA="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 45 \
  "https://api.github.com/repos/apple/coreai-models/commits/${COREAI_REVISION}")"
if [[ "$(jq -r '.sha // empty' <<<"${COREAI_METADATA}")" != "${COREAI_REVISION}" || \
      "$(jq -r '.commit.committer.date // empty' <<<"${COREAI_METADATA}" | cut -c 1-10)" != "${COREAI_DATE}" ]]; then
  print -u2 "Apple Core AI source revision/date no longer matches the catalog."
  exit 6
fi
print "Verified apple/coreai-models@${COREAI_REVISION} (${COREAI_DATE})"

print "All Local AI upstream source pins verified."
