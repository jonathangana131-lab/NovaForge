#!/bin/zsh
set -euo pipefail

readonly REPOSITORY_ROOT="${0:A:h:h}"
readonly CATALOG_PATH="${1:-${REPOSITORY_ROOT}/AgentPad/Resources/LocalModelCatalog.v2.json}"
readonly CORPUS_PATH="${REPOSITORY_ROOT}/AgentPad/Resources/LocalAI2Corpus.v1.json"
readonly CORPUS_FIXTURE_PATH="${REPOSITORY_ROOT}/AgentPadTests/Fixtures/LocalAI2/corpus-v1.json"
readonly CORPUS_SUMS_PATH="${REPOSITORY_ROOT}/AgentPadTests/Fixtures/LocalAI2/SHA256SUMS"
readonly COMPANION_MANIFEST_PATH="${REPOSITORY_ROOT}/scripts/companion/qwen3.8-27b.manifest.json"
readonly POWER_CANDIDATES_PATH="${REPOSITORY_ROOT}/scripts/out-of-core/qwen3.8-27b-candidates.manifest.json"
readonly EXPECTED_SHA256="d46f4fdeebe03bf4da13ecfaeacd8da8b9ce02c91a8b710bb799a5abdc817e24"
readonly EXPECTED_POWER_CANDIDATES_SHA256="2cdb7753f4d384841bfca45de5f4c04ddd5d5c1676f7511316a6759885e72a65"
readonly EXPECTED_CORPUS_SHA256="75fd1e718c227ee71f350c336522074a0dc66d56b144a1eed028c79cc35519e4"

for command_name in cmp jq shasum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    print -u2 "Missing required command: ${command_name}"
    exit 2
  fi
done

readonly ACTUAL_SHA256="$(shasum -a 256 "${CATALOG_PATH}" | awk '{print $1}')"
readonly ACTUAL_CORPUS_SHA256="$(shasum -a 256 "${CORPUS_PATH}" | awk '{print $1}')"
readonly FIXTURE_CORPUS_SHA256="$(shasum -a 256 "${CORPUS_FIXTURE_PATH}" | awk '{print $1}')"
readonly ACTUAL_POWER_CANDIDATES_SHA256="$(shasum -a 256 "${POWER_CANDIDATES_PATH}" | awk '{print $1}')"

if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
  print -u2 "Catalog pin mismatch: expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"
  exit 1
fi
if [[ "${ACTUAL_POWER_CANDIDATES_SHA256}" != "${EXPECTED_POWER_CANDIDATES_SHA256}" ]]; then
  print -u2 "Power candidate manifest pin mismatch: expected ${EXPECTED_POWER_CANDIDATES_SHA256}, got ${ACTUAL_POWER_CANDIDATES_SHA256}"
  exit 1
fi
if [[ "${ACTUAL_CORPUS_SHA256}" != "${EXPECTED_CORPUS_SHA256}" ]]; then
  print -u2 "Evaluation corpus pin mismatch: expected ${EXPECTED_CORPUS_SHA256}, got ${ACTUAL_CORPUS_SHA256}"
  exit 1
fi
if [[ "${FIXTURE_CORPUS_SHA256}" != "${EXPECTED_CORPUS_SHA256}" ]] || \
   ! cmp -s "${CORPUS_PATH}" "${CORPUS_FIXTURE_PATH}"; then
  print -u2 "App and test evaluation corpus copies differ or the fixture is unpinned."
  exit 1
fi
if [[ "$(awk 'NF { print $1 " " $2 }' "${CORPUS_SUMS_PATH}")" != \
      "${EXPECTED_CORPUS_SHA256} corpus-v1.json" ]]; then
  print -u2 "Evaluation fixture SHA256SUMS does not bind corpus-v1.json exactly."
  exit 1
fi

# The digest pins exact bytes. These assertions additionally fail with an
# actionable schema error when a future catalog edit weakens provenance,
# device admission, or the iPhone 12 companion boundary.
jq -e '
  def hex40: type == "string" and test("^[0-9a-f]{40}$");
  def hex64: type == "string" and test("^[0-9a-f]{64}$");
  def pinned($revision): type == "string" and startswith("https://") and contains($revision);
  def all_unique: length == (unique | length);
  .generatedAt[0:10] as $generated_day |
  .models as $models |
  .schemaVersion == 2 and
  (.generatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  ($models | length == 10) and
  ([$models[].id] | all_unique) and
  ([$models[] | select(.artifactKind == "downloadable") | .filename] | all_unique) and
  ([$models[] | select(.isIPhone12SafeDefault)] | length == 1) and
  ([$models[].tier] | unique | sort) == ["balanced", "fast", "instant", "power"] and
  ([$models[] | select(
    (.id | type == "string" and length > 0) and
    (.displayName | type == "string" and length > 0) and
    (.immutableRevision | hex40) and
    (.immutableRevision as $revision |
      (.downloadURL | pinned($revision)) and
      (.sourceURL | pinned($revision)) and
      (.licenseURL | pinned($revision))) and
    (.releaseDateISO8601 <= $generated_day) and
    (.contextTokens > 0) and (.maxNewTokens > 0) and
    (.estimatedPeakMemoryBytes >= 0) and
    (.measuredPeakMemoryBytes == null)
  )] | length == ($models | length)) and
  ([$models[] | select(.artifactKind == "downloadable") | select(
    (.engineType == "llamaCpp") and (.executionLocation == "local") and
    (.filename | test("^[^/\\\\]+\\.gguf$")) and
    (.expectedBytes > 0) and (.expectedSHA256 | hex64) and
    (.immutableRevision as $revision | .filename as $filename |
      (.downloadURL | contains("/resolve/" + $revision + "/" + $filename)))
  )] | length == ([$models[] | select(.artifactKind == "downloadable")] | length)) and
  ([$models[] | select(.artifactKind != "downloadable") | select(
    .expectedBytes == 0 and .expectedSHA256 == ""
  )] | length == ([$models[] | select(.artifactKind != "downloadable")] | length)) and
  any($models[];
    .id == "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M" and
    .isIPhone12SafeDefault and .physicalBenchmarkStatus == "legacyProven"
  ) and
  any($models[];
    .id == "LiquidAI/LFM2.5-2.6B-QAD-Q4_0" and
    .physicalBenchmarkStatus == "unsupported" and
    (.minimumPhysicalMemoryBytes >= 6000000000)
  ) and
  any($models[];
    .id == "unsloth/Qwen3.8-27B-UD-IQ1_S-Power-On-Device" and
    .tier == "power" and .engineType == "llamaCpp" and
    .executionLocation == "local" and .artifactKind == "downloadable" and
    .immutableRevision == "f4480441d4fb4fe2e283c5d1e05d230195afd939" and
    .expectedBytes == 6192222304 and
    .expectedSHA256 == "ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d" and
    .minimumPhysicalMemoryBytes == 4000000000 and
    .physicalBenchmarkStatus == "pending" and
    (.isIPhone12SafeDefault | not)
  ) and
  any($models[];
    .id == "unsloth/Qwen3.8-27B-UD-IQ2_XXS-Power-On-Device" and
    .tier == "power" and .engineType == "llamaCpp" and
    .executionLocation == "local" and .artifactKind == "downloadable" and
    .immutableRevision == "f4480441d4fb4fe2e283c5d1e05d230195afd939" and
    .expectedBytes == 9010048064 and
    .expectedSHA256 == "8d1b37297d6cf98303cd396896f35e01089ddcc904053a9c6997f7a1c35b8524" and
    .physicalBenchmarkStatus == "pending" and
    (.isIPhone12SafeDefault | not)
  ) and
  any($models[];
    .id == "unsloth/Qwen3.8-27B-Q3_K_M-Power-On-Device" and
    .tier == "power" and .engineType == "llamaCpp" and
    .executionLocation == "local" and .artifactKind == "downloadable" and
    .immutableRevision == "f4480441d4fb4fe2e283c5d1e05d230195afd939" and
    .expectedBytes == 13818690528 and
    .expectedSHA256 == "7f3b845b563888ec3abc269474cf744bf703a7ce8766dbb7f696c63975facfd7" and
    .physicalBenchmarkStatus == "pending" and
    (.isIPhone12SafeDefault | not)
  ) and
  any($models[];
    .id == "Qwen/Qwen3.8-27B-Power-Companion" and
    .tier == "power" and .engineType == "companion" and
    .executionLocation == "lan" and .artifactKind == "endpointManaged" and
    (.isIPhone12SafeDefault | not) and
    .physicalBenchmarkStatus == "companionOnly"
  ) and
  any($models[];
    .engineType == "coreAI" and .artifactKind == "exportRequired" and
    (.supportedDeviceClasses | any(contains("not iPhone 12")))
  )
' "${CATALOG_PATH}" >/dev/null || {
  print -u2 "Local AI catalog schema or safety invariant failed."
  exit 1
}

jq -e '
  .model_id == "Qwen/Qwen3.8-27B" and
  .immutable_revision == "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0" and
  .license == "Apache-2.0" and .text_only == true and
  .vision_projection_included == false and
  .artifact_repository == "unsloth/Qwen3.8-27B-GGUF" and
  .artifact_revision == "f4480441d4fb4fe2e283c5d1e05d230195afd939" and
  .artifact_filename == "Qwen3.8-27B-UD-IQ1_S.gguf" and
  .artifact_quantization == "UD-IQ1_S" and
  .artifact_bytes == 6192222304 and
  .artifact_sha256 == "ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d" and
  .default_context == 1024 and .default_max_tokens == 128 and
  .generation_lease_count == 1 and
  (.mtp_policy | startswith("disabled"))
' "${COMPANION_MANIFEST_PATH}" >/dev/null || {
  print -u2 "Power companion manifest is not bound to the exact text-only artifact and conservative runtime policy."
  exit 1
}

jq -e '
  .schema_version == 1 and
  .model_id == "Qwen/Qwen3.8-27B" and
  .model_revision == "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0" and
  .license == "Apache-2.0" and .text_only == true and
  .vision_projection_included == false and
  .artifact_repository == "unsloth/Qwen3.8-27B-GGUF" and
  .artifact_revision == "f4480441d4fb4fe2e283c5d1e05d230195afd939" and
  .runtime_policy.context_tokens == 512 and
  .runtime_policy.maximum_output_tokens == 128 and
  .runtime_policy.resident_budget_bytes == 1500000000 and
  .runtime_policy.generation_lease_count == 1 and
  .runtime_policy.lan_fallback == "forbidden" and
  (.candidates | length == 3) and
  ([.candidates[].key] == ["iq1", "iq2", "q3"]) and
  any(.candidates[]; .key == "iq1" and .bytes == 6192222304 and .sha256 == "ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d") and
  any(.candidates[]; .key == "iq2" and .bytes == 9010048064 and .sha256 == "8d1b37297d6cf98303cd396896f35e01089ddcc904053a9c6997f7a1c35b8524") and
  any(.candidates[]; .key == "q3" and .bytes == 13818690528 and .sha256 == "7f3b845b563888ec3abc269474cf744bf703a7ce8766dbb7f696c63975facfd7")
' "${POWER_CANDIDATES_PATH}" >/dev/null || {
  print -u2 "Power out-of-core candidate manifest is not exact and fail-closed."
  exit 1
}

jq -e '
  .schemaVersion == 1 and
  .corpusRevision == "task4-wave1" and
  (.receiptContract.schemaVersion == 2) and
  (.receiptContract.requiredExecutionClasses == ["simulator", "generic_build", "physical", "unavailable"]) and
  (.cases | length == 19) and
  ([.cases[].id] | length == (unique | length)) and
  ([.cases[].category] | unique | sort) == ["instruction_following", "multi_turn", "performance", "repetition", "repository_qa", "summarization", "swift_generation", "swift_repair", "tool_refusal", "tool_selection"] and
  all(.cases[]; (.id | length > 0) and (.category | length > 0)) and
  any(.cases[]; .category == "performance" and (.minimumUsefulOutputTokens // 0) >= 128) and
  any(.cases[]; .category == "tool_refusal" and has("expectedTool") and .expectedTool == null) and
  any(.cases[]; .category == "repository_qa" and (.mustContainAny // [] | any(. == "unknown")))
' "${CORPUS_PATH}" >/dev/null || {
  print -u2 "Local AI evaluation corpus schema or safety invariant failed."
  exit 1
}

print "Local AI catalog pin and schema verified: ${ACTUAL_SHA256}"
print "Local AI evaluation corpus pin and schema verified: ${ACTUAL_CORPUS_SHA256}"
