#!/bin/zsh
set -euo pipefail

# Companion benchmark harness. The runtime adapter is deliberately external:
# this keeps MLX/llama.cpp versioning and licenses out of the iOS project.
# Adapters must implement the JSONL contract documented in Docs/Companion-Benchmarking.md.

typeset runtime=""
typeset runner="${COMPANION_RUNNER:-}"
typeset output=""
typeset manifest=""
integer runs=2
integer context=1024
integer max_tokens=128
typeset temperature="0.2"
typeset top_p="0.95"
integer seed=42

usage() {
  print "Usage: $0 --runtime mlx|llama-cpp --runner PATH --manifest PATH --output PATH [options]"
  print "Options: --runs N --context N --max-tokens N --temperature N --top-p N --seed N"
}

while (( $# > 0 )); do
  case "$1" in
    --runtime) runtime="${2:-}"; shift 2 ;;
    --runner) runner="${2:-}"; shift 2 ;;
    --manifest) manifest="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --runs) runs="${2:-}"; shift 2 ;;
    --context) context="${2:-}"; shift 2 ;;
    --max-tokens) max_tokens="${2:-}"; shift 2 ;;
    --temperature) temperature="${2:-}"; shift 2 ;;
    --top-p) top_p="${2:-}"; shift 2 ;;
    --seed) seed="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown argument: $1"; usage >&2; exit 64 ;;
  esac
done

[[ "$runtime" == "mlx" || "$runtime" == "llama-cpp" ]] || { print -u2 "--runtime must be mlx or llama-cpp"; exit 64; }
[[ "$(uname -m)" == "arm64" ]] || { print -u2 "Apple Silicon arm64 is required"; exit 2; }
[[ -n "$runner" && -x "$runner" ]] || { print -u2 "Runner must be an executable: $runner"; exit 2; }
[[ -r "$manifest" ]] || { print -u2 "Readable manifest required: $manifest"; exit 2; }
[[ -n "$output" ]] || { print -u2 "--output is required"; exit 64; }
command -v jq >/dev/null 2>&1 || { print -u2 "jq is required"; exit 2; }
command -v shasum >/dev/null 2>&1 || { print -u2 "shasum is required"; exit 2; }
[[ "$runs" == <-> && "$runs" -gt 0 && "$runs" -le 20 ]] || { print -u2 "runs must be 1..20"; exit 64; }
[[ "$context" == <-> && "$context" -gt 0 && "$context" -le 32768 ]] || { print -u2 "invalid context"; exit 64; }
[[ "$max_tokens" == <-> && "$max_tokens" -gt 0 && "$max_tokens" -le 4096 ]] || { print -u2 "invalid max tokens"; exit 64; }

jq -e '
  type == "object" and
  (.model_id | type == "string" and length > 0) and
  (.immutable_revision | type == "string" and test("^[0-9a-f]{40}$")) and
  .text_only == true and
  (.prompt_corpus | type == "string" and length > 0)
' "$manifest" >/dev/null || {
  print -u2 "Manifest must describe a text-only model at an exact immutable revision; refusing to benchmark."
  exit 3
}
typeset model_id="$(jq -er '.model_id' "$manifest")"
typeset revision="$(jq -er '.immutable_revision' "$manifest")"
typeset prompt_file="$(jq -er '.prompt_corpus' "$manifest")"
typeset repo_root="${0:A:h:h:h}"
if [[ "$prompt_file" != /* ]]; then
  prompt_file="$repo_root/$prompt_file"
fi
[[ -r "$prompt_file" ]] || { print -u2 "Prompt corpus is missing: $prompt_file"; exit 2; }
typeset prompt_sha="$(shasum -a 256 "$prompt_file" | awk '{print $1}')"

typeset tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/novaforge-companion.XXXXXX")"
trap 'rm -rf -- "$tmpdir"' EXIT
typeset attestation="$tmpdir/attestation.json"
if ! "$runner" --describe-json >"$attestation"; then
  print -u2 "Runtime identity/capability attestation failed; refusing to benchmark."
  exit 3
fi

jq -e --arg runtime "$runtime" --arg model "$model_id" --arg revision "$revision" \
  'type == "object" and .runtime == $runtime and .model_id == $model and
   .immutable_revision == $revision and (.context_limit | type == "number") and
   .text_only == true and (.capabilities | type == "array") and
   (([.capabilities[] | ascii_downcase] | index("text")) != null) and
   (([.capabilities[] | ascii_downcase] | index("streaming")) != null) and
   (.mtp_supported | type == "boolean") and (.mtp_verified | type == "boolean")' \
  "$attestation" >/dev/null || {
    print -u2 "Runtime attestation does not match the pinned manifest; refusing to send prompts."; exit 3
  }
integer context_limit="$(jq -er '.context_limit' "$attestation")"
(( context <= context_limit )) || { print -u2 "Requested context exceeds attested context limit"; exit 3; }

typeset mtp_mode="disabled"
if [[ "$(jq -r '.mtp_supported and .mtp_verified' "$attestation")" == "true" ]]; then
  mtp_mode="native"
fi

mkdir -p "${output:h}"
typeset header
header="$(jq -cn --arg schema "novaforge.companion-benchmark.v1" --arg runtime "$runtime" \
  --arg model "$model_id" --arg revision "$revision" --arg prompt_sha "$prompt_sha" \
  --arg mtp "$mtp_mode" --argjson context "$context" --argjson max_tokens "$max_tokens" \
  --argjson runs "$runs" --arg temperature "$temperature" --arg top_p "$top_p" --argjson seed "$seed" \
  '{record_type:"header",schema:$schema,runtime:$runtime,model_id:$model,immutable_revision:$revision,
    prompt_corpus_sha256:$prompt_sha,context:$context,max_tokens:$max_tokens,temperature:($temperature|tonumber),
    top_p:($top_p|tonumber),seed:$seed,runs:$runs,mtp_mode:$mtp,attestation:input}' <"$attestation")"
print -r -- "$header" >"$output"

integer run=1
while (( run <= runs )); do
  typeset events="$tmpdir/events-$run.jsonl"
  typeset stderr_file="$tmpdir/stderr-$run.txt"
  if ! "$runner" --run-jsonl --prompt-file "$prompt_file" \
      --context "$context" --max-tokens "$max_tokens" --temperature "$temperature" \
      --top-p "$top_p" --seed "$seed" --mtp "$mtp_mode" >"$events" 2>"$stderr_file"; then
    print -u2 "Runtime failed on run $run; evidence is incomplete and no result is reported."
    exit 4
  fi
  [[ -s "$events" ]] || { print -u2 "Runtime emitted no events on run $run"; exit 4; }
  typeset done_json="$(awk '$0 ~ /^{/ { line=$0 } END { print line }' "$events")"
  jq -e --argjson run "$run" --arg mtp "$mtp_mode" \
    'type == "object" and .event == "done" and .run == $run and .mtp_mode == $mtp and
     (.ttft_ms|type=="number") and (.prompt_ms|type=="number") and (.decode_ms|type=="number") and
     (.generated_tokens|type=="number") and (.peak_memory_bytes|type=="number") and
     (.thermal_before|type=="string") and (.thermal_after|type=="string") and
     (.quality|type=="object")' <<<"$done_json" >/dev/null || {
      print -u2 "Missing or malformed measured done event on run $run; refusing to emit a result."; exit 4;
    }
  jq -c --argjson run "$run" --arg runtime "$runtime" --arg model "$model_id" \
    --arg revision "$revision" --arg prompt_sha "$prompt_sha" \
    '. + {record_type:"run",run:$run,runtime:$runtime,model_id:$model,immutable_revision:$revision,
          prompt_corpus_sha256:$prompt_sha,measurement_source:"runtime_adapter"}' <<<"$done_json" >>"$output"
  (( run++ ))
done

print -r -- "$(jq -cn --arg note "No winner is declared. Compare only after independent review of these measured runs." \
  '{record_type:"decision",winner:null,decision_status:"measurements_only",note:$note}')" >>"$output"
print "Wrote measured evidence to $output (winner: none)"
