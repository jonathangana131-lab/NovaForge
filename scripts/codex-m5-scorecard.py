#!/usr/bin/env python3
"""Build and gate a content-free paired V1/V2 M5 latency/parity scorecard."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
TOP_LEVEL_KEYS = {"schemaVersion", "route", "samples"}
ROUTE_KEYS = {
    "provider",
    "model",
    "temperature",
    "maxOutputTokens",
    "sampleTarget",
}
SAMPLE_KEYS = {
    "pairID",
    "engine",
    "success",
    "acceptanceMs",
    "ttftMs",
    "totalMs",
    "contextSHA256",
    "transcriptSHA256",
    "evidenceSHA256",
    "workspaceBeforeSHA256",
    "workspaceAfterSHA256",
    "errorCategory",
}
ENGINES = {"v1", "v2"}
MINIMUM_PAIRED_SAMPLES = 100


class ScorecardInputError(ValueError):
    pass


def reject_unknown_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = set(value) - allowed
    if unknown:
        raise ScorecardInputError(
            f"{label} contains forbidden or unknown fields: {sorted(unknown)}"
        )


def require_finite_nonnegative(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ScorecardInputError(f"{label} must be a number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ScorecardInputError(f"{label} must be finite and nonnegative")
    return number


def require_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise ScorecardInputError(f"{label} must be a lowercase sha256 digest")
    return value


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise ScorecardInputError("cannot calculate a percentile without samples")
    ordered = sorted(values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def validate_and_group(payload: Any) -> tuple[dict[str, Any], dict[str, dict[str, dict[str, Any]]]]:
    if not isinstance(payload, dict):
        raise ScorecardInputError("scorecard input must be a JSON object")
    reject_unknown_keys(payload, TOP_LEVEL_KEYS, "input")
    if payload.get("schemaVersion") != 1:
        raise ScorecardInputError("schemaVersion must equal 1")

    route = payload.get("route")
    if not isinstance(route, dict):
        raise ScorecardInputError("route must be an object")
    reject_unknown_keys(route, ROUTE_KEYS, "route")
    for key in ("provider", "model"):
        value = route.get(key)
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 256:
            raise ScorecardInputError(f"route.{key} must be a bounded identity")
    require_finite_nonnegative(route.get("temperature"), "route.temperature")
    max_output = route.get("maxOutputTokens")
    if isinstance(max_output, bool) or not isinstance(max_output, int) or max_output <= 0:
        raise ScorecardInputError("route.maxOutputTokens must be a positive integer")
    sample_target = route.get("sampleTarget")
    if sample_target != MINIMUM_PAIRED_SAMPLES:
        raise ScorecardInputError(
            f"route.sampleTarget must equal {MINIMUM_PAIRED_SAMPLES}"
        )

    samples = payload.get("samples")
    if not isinstance(samples, list):
        raise ScorecardInputError("samples must be an array")

    grouped: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for index, sample in enumerate(samples):
        label = f"samples[{index}]"
        if not isinstance(sample, dict):
            raise ScorecardInputError(f"{label} must be an object")
        reject_unknown_keys(sample, SAMPLE_KEYS, label)
        pair_id = sample.get("pairID")
        if (
            not isinstance(pair_id, str)
            or not pair_id
            or len(pair_id.encode("utf-8")) > 128
            or any(character.isspace() for character in pair_id)
        ):
            raise ScorecardInputError(f"{label}.pairID must be a bounded opaque identity")
        engine = sample.get("engine")
        if engine not in ENGINES:
            raise ScorecardInputError(f"{label}.engine must be v1 or v2")
        if engine in grouped[pair_id]:
            raise ScorecardInputError(f"duplicate {engine} sample for pair {pair_id}")
        if not isinstance(sample.get("success"), bool):
            raise ScorecardInputError(f"{label}.success must be Boolean")
        for metric in ("acceptanceMs", "ttftMs", "totalMs"):
            sample[metric] = require_finite_nonnegative(
                sample.get(metric), f"{label}.{metric}"
            )
        for digest_key in (
            "contextSHA256",
            "transcriptSHA256",
            "evidenceSHA256",
            "workspaceBeforeSHA256",
            "workspaceAfterSHA256",
        ):
            sample[digest_key] = require_digest(
                sample.get(digest_key), f"{label}.{digest_key}"
            )
        error_category = sample.get("errorCategory")
        if error_category is not None and (
            not isinstance(error_category, str)
            or len(error_category.encode("utf-8")) > 64
        ):
            raise ScorecardInputError(f"{label}.errorCategory must be a bounded taxonomy value")
        grouped[pair_id][engine] = sample

    if len(grouped) < MINIMUM_PAIRED_SAMPLES:
        raise ScorecardInputError(
            f"need at least {MINIMUM_PAIRED_SAMPLES} paired samples"
        )
    incomplete = sorted(pair_id for pair_id, pair in grouped.items() if set(pair) != ENGINES)
    if incomplete:
        raise ScorecardInputError(f"unpaired sample identities: {incomplete[:5]}")
    return route, grouped


def build_scorecard(route: dict[str, Any], grouped: dict[str, dict[str, dict[str, Any]]]) -> dict[str, Any]:
    metrics: dict[str, dict[str, float]] = {}
    for engine in sorted(ENGINES):
        engine_samples = [pair[engine] for pair in grouped.values()]
        metrics[engine] = {
            "sampleCount": len(engine_samples),
            "acceptanceP50Ms": percentile([sample["acceptanceMs"] for sample in engine_samples], 0.50),
            "acceptanceP95Ms": percentile([sample["acceptanceMs"] for sample in engine_samples], 0.95),
            "ttftP50Ms": percentile([sample["ttftMs"] for sample in engine_samples], 0.50),
            "ttftP95Ms": percentile([sample["ttftMs"] for sample in engine_samples], 0.95),
            "totalP50Ms": percentile([sample["totalMs"] for sample in engine_samples], 0.50),
            "totalP95Ms": percentile([sample["totalMs"] for sample in engine_samples], 0.95),
            "failureCount": sum(not sample["success"] for sample in engine_samples),
        }

    parity_failures: list[str] = []
    workspace_failures: list[str] = []
    for pair_id, pair in sorted(grouped.items()):
        v1, v2 = pair["v1"], pair["v2"]
        if any(not pair[engine]["success"] for engine in ENGINES):
            parity_failures.append(pair_id)
            continue
        if any(
            v1[key] != v2[key]
            for key in ("contextSHA256", "transcriptSHA256", "evidenceSHA256")
        ):
            parity_failures.append(pair_id)
        for engine in ENGINES:
            sample = pair[engine]
            if sample["workspaceBeforeSHA256"] != sample["workspaceAfterSHA256"]:
                workspace_failures.append(f"{pair_id}:{engine}")

    v1_ttft = metrics["v1"]["ttftP95Ms"]
    v1_total = metrics["v1"]["totalP95Ms"]
    def relative_p95(candidate: float, baseline: float) -> float | None:
        if baseline == 0:
            return 1.0 if candidate == 0 else None
        return candidate / baseline

    ttft_ratio = relative_p95(metrics["v2"]["ttftP95Ms"], v1_ttft)
    total_ratio = relative_p95(metrics["v2"]["totalP95Ms"], v1_total)

    checks = {
        "minimumPairedSamples": len(grouped) >= MINIMUM_PAIRED_SAMPLES,
        "allRunsSuccessful": all(metrics[engine]["failureCount"] == 0 for engine in ENGINES),
        "exactContextTranscriptEvidenceParity": not parity_failures,
        "readOnlyWorkspaceUnchanged": not workspace_failures,
        "v2AcceptanceP95AtMost200Ms": metrics["v2"]["acceptanceP95Ms"] <= 200.0,
        "v2TTFTP95WithinTenPercent": ttft_ratio is not None and ttft_ratio <= 1.10,
        "v2TotalP95WithinTenPercent": total_ratio is not None and total_ratio <= 1.10,
    }
    return {
        "schemaVersion": 1,
        "status": "pass" if all(checks.values()) else "fail",
        "route": route,
        "pairedSampleCount": len(grouped),
        "metrics": metrics,
        "ratios": {
            "v2ToV1TTFTP95": ttft_ratio,
            "v2ToV1TotalP95": total_ratio,
            "rolloutPauseThreshold": 1.15,
        },
        "checks": checks,
        "failureSummary": {
            "parityPairCount": len(parity_failures),
            "workspaceMutationCount": len(workspace_failures),
            "parityPairIDs": parity_failures[:20],
            "workspaceSamples": workspace_failures[:20],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        route, grouped = validate_and_group(payload)
        scorecard = build_scorecard(route, grouped)
    except (OSError, json.JSONDecodeError, ScorecardInputError) as error:
        print(f"M5 scorecard input rejected: {error}", file=sys.stderr)
        return 2

    encoded = json.dumps(scorecard, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.output:
        try:
            args.output.write_text(encoded, encoding="utf-8")
        except OSError as error:
            print(f"M5 scorecard output failed: {error}", file=sys.stderr)
            return 2
    else:
        sys.stdout.write(encoded)
    return 0 if scorecard["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
