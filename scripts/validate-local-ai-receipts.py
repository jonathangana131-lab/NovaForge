#!/usr/bin/env python3
"""Fail-closed admission gate for physical and Core AI success receipts."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


class ReceiptError(ValueError):
    pass


def load(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise ReceiptError(f"{label} receipt is absent: {path}")
    if path.stat().st_size < 2 or path.stat().st_size > 4 * 1024 * 1024:
        raise ReceiptError(f"{label} receipt is outside the bounded size limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReceiptError(f"{label} receipt is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ReceiptError(f"{label} receipt must be a JSON object")
    return value


def required_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReceiptError(f"{label} is missing")
    if pattern and not pattern.fullmatch(value):
        raise ReceiptError(f"{label} has an invalid identity")
    return value


def digest(value: Any, label: str) -> str:
    return required_string(value, label, SHA256)


def nonnegative_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ReceiptError(f"{label} must be a non-negative integer")
    return value


def number(value: Any, label: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ReceiptError(f"{label} must be a finite number")
    if positive and value <= 0:
        raise ReceiptError(f"{label} must be positive")
    return float(value)


def fraction(value: Any, label: str) -> float:
    measured = number(value, label)
    if measured < 0 or measured > 1:
        raise ReceiptError(f"{label} must be between 0 and 1")
    return measured


def passed(value: Any, label: str) -> None:
    if value not in {"pass", "passed"}:
        raise ReceiptError(f"{label} did not pass")


def validate_receipt(receipt: dict[str, Any], label: str) -> None:
    if receipt.get("schemaVersion") != 2:
        raise ReceiptError(f"{label} receipt must use schemaVersion 2")
    if receipt.get("receiptKind") not in {"local_ai_benchmark", "local_ai_evaluation"}:
        raise ReceiptError(f"{label} receipt has no recognized receiptKind")
    if receipt.get("executionClass") != "physical":
        raise ReceiptError(f"{label} receipt is not physical evidence")
    if receipt.get("availability") != "verified" or receipt.get("claimsAllowed") is not True:
        raise ReceiptError(f"{label} receipt is unavailable, partial, or non-claiming")
    required_string(receipt.get("receiptID"), f"{label}.receiptID")
    run_id = required_string(receipt.get("runID"), f"{label}.runID")
    required_string(receipt.get("recordedAt"), f"{label}.recordedAt")
    device = receipt.get("device")
    if not isinstance(device, dict):
        raise ReceiptError(f"{label}.device is missing")
    required_string(device.get("rawModelIdentifier"), f"{label}.device.rawModelIdentifier")
    required_string(device.get("displayName"), f"{label}.device.displayName")
    required_string(device.get("osDeviceIdentifier"), f"{label}.device.osDeviceIdentifier")
    required_string(device.get("architecture"), f"{label}.device.architecture")
    if device.get("isSimulator") is not False or device.get("isPhysicalDevice") is not True:
        raise ReceiptError(f"{label} device flags do not prove a physical run")
    build = receipt.get("build")
    if not isinstance(build, dict):
        raise ReceiptError(f"{label}.build is missing")
    source_commit = required_string(build.get("sourceCommit"), f"{label}.build.sourceCommit", COMMIT)
    for key in ("appVersion", "buildNumber", "configuration", "sdk", "xcode"):
        required_string(build.get(key), f"{label}.build.{key}")
    build_app_hash = digest(build.get("appSHA256"), f"{label}.build.appSHA256")
    required_string(receipt.get("sourceCommit", source_commit), f"{label}.sourceCommit", COMMIT)
    if receipt.get("sourceCommit") != source_commit:
        raise ReceiptError(f"{label} sourceCommit is not bound to build.sourceCommit")
    hashes = receipt.get("artifactHashes")
    if not isinstance(hashes, dict):
        raise ReceiptError(f"{label}.artifactHashes is missing")
    for key in ("appSHA256", "modelSHA256", "corpusSHA256"):
        digest(hashes.get(key), f"{label}.artifactHashes.{key}")
    if hashes["appSHA256"] != build_app_hash:
        raise ReceiptError(f"{label} artifact app hash is not bound to build.appSHA256")
    model = receipt.get("model")
    if not isinstance(model, dict):
        raise ReceiptError(f"{label}.model is missing")
    for key in ("id", "immutableRevision", "quantization"):
        required_string(model.get(key), f"{label}.model.{key}")
    if digest(model.get("artifactSHA256"), f"{label}.model.artifactSHA256") != hashes["modelSHA256"]:
        raise ReceiptError(f"{label} model artifact hash is not bound to artifactHashes")
    if nonnegative_integer(model.get("artifactBytes"), f"{label}.model.artifactBytes") == 0:
        raise ReceiptError(f"{label}.model.artifactBytes must be positive")
    operating_system = receipt.get("operatingSystem")
    if not isinstance(operating_system, dict):
        raise ReceiptError(f"{label}.operatingSystem is missing")
    for key in ("name", "version", "build"):
        required_string(operating_system.get(key), f"{label}.operatingSystem.{key}")
    quality = receipt.get("quality")
    if not isinstance(quality, dict):
        raise ReceiptError(f"{label}.quality is missing")
    required_string(quality.get("corpusID"), f"{label}.quality.corpusID")
    digest(quality.get("corpusSHA256"), f"{label}.quality.corpusSHA256")
    if quality["corpusSHA256"] != hashes["corpusSHA256"]:
        raise ReceiptError(f"{label} quality corpus hash is not bound to artifactHashes")
    total_cases = nonnegative_integer(quality.get("totalCaseCount"), f"{label}.quality.totalCaseCount")
    passed_cases = nonnegative_integer(quality.get("passedCaseCount"), f"{label}.quality.passedCaseCount")
    if total_cases == 0 or passed_cases > total_cases or not isinstance(quality.get("perCaseResults"), list) or len(quality["perCaseResults"]) != total_cases:
        raise ReceiptError(f"{label}.quality per-case results are incomplete")
    if not isinstance(quality.get("score"), (int, float)) or isinstance(quality.get("score"), bool):
        raise ReceiptError(f"{label}.quality.score is missing")
    if not isinstance(quality.get("failureReasons"), list):
        raise ReceiptError(f"{label}.quality.failureReasons is missing")
    engine = receipt.get("engine")
    if not isinstance(engine, dict):
        raise ReceiptError(f"{label}.engine is missing")
    required_string(engine.get("type"), f"{label}.engine.type")
    for key in ("engineRevision", "backend", "wrapperRevision", "executionLocation"):
        required_string(engine.get(key), f"{label}.engine.{key}")
    if "core" in engine["type"].lower() and "ai" in engine["type"].lower():
        required_string(engine.get("supportedHardware"), f"{label}.engine.supportedHardware")
        digest(hashes.get("aotAssetSHA256"), f"{label}.artifactHashes.aotAssetSHA256")
    generation = receipt.get("generation")
    if not isinstance(generation, dict):
        raise ReceiptError(f"{label}.generation is missing")
    context_tokens = nonnegative_integer(generation.get("contextTokens"), f"{label}.generation.contextTokens")
    maximum_output = nonnegative_integer(generation.get("maximumOutputTokens"), f"{label}.generation.maximumOutputTokens")
    if context_tokens == 0 or maximum_output < 128:
        raise ReceiptError(f"{label}.generation does not admit a 128-token physical run")
    sampling = receipt.get("sampling")
    if not isinstance(sampling, dict) or any(key not in sampling for key in ("temperature", "topP", "topK", "minP", "seed", "repetitionPenalty")):
        raise ReceiptError(f"{label}.sampling is incomplete")
    load = receipt.get("load")
    if not isinstance(load, dict) or any(not isinstance(load.get(key), dict) for key in ("cold", "warm", "postUnloadRecovery")):
        raise ReceiptError(f"{label}.load is incomplete")
    for attempt_name in ("cold", "warm", "postUnloadRecovery"):
        attempt = load[attempt_name]
        required_attempt_keys = (
            "attempted", "available", "startedAt", "completedAt", "durationSeconds",
            "modelResidentBefore", "modelResidentAfter", "reason",
        )
        if any(key not in attempt for key in required_attempt_keys):
            raise ReceiptError(f"{label}.load.{attempt_name} is incomplete")
        if attempt["attempted"] is not True or attempt["available"] is not True:
            raise ReceiptError(f"{label}.load.{attempt_name} was not completed")
        required_string(attempt["startedAt"], f"{label}.load.{attempt_name}.startedAt")
        required_string(attempt["completedAt"], f"{label}.load.{attempt_name}.completedAt")
        number(attempt["durationSeconds"], f"{label}.load.{attempt_name}.durationSeconds", positive=True)
        if not isinstance(attempt["modelResidentBefore"], bool) or not isinstance(attempt["modelResidentAfter"], bool):
            raise ReceiptError(f"{label}.load.{attempt_name} residency evidence is missing")
    if load["cold"]["modelResidentBefore"] is not False or load["cold"]["modelResidentAfter"] is not True:
        raise ReceiptError(f"{label}.load.cold does not prove a cold load")
    if load["warm"]["modelResidentBefore"] is not True or load["warm"]["modelResidentAfter"] is not True:
        raise ReceiptError(f"{label}.load.warm does not prove reuse")
    if load["postUnloadRecovery"]["modelResidentBefore"] is not False or load["postUnloadRecovery"]["modelResidentAfter"] is not True:
        raise ReceiptError(f"{label}.load.postUnloadRecovery does not prove recovery")

    performance = receipt.get("performance")
    performance_keys = ("promptTokensPerSecond", "timeToFirstTokenSeconds", "decodeTokensPerSecond", "usefulTokens", "totalDurationSeconds")
    if not isinstance(performance, dict) or any(key not in performance for key in performance_keys):
        raise ReceiptError(f"{label}.performance is incomplete")
    for key in ("promptTokensPerSecond", "timeToFirstTokenSeconds", "decodeTokensPerSecond", "totalDurationSeconds"):
        number(performance[key], f"{label}.performance.{key}", positive=True)
    if nonnegative_integer(performance["usefulTokens"], f"{label}.performance.usefulTokens") < 128:
        raise ReceiptError(f"{label}.performance useful-token gate is below 128")

    resources = receipt.get("resources")
    resource_keys = ("peakMemoryBytes", "memoryCeilingBytes", "thermalBefore", "thermalAfter", "thermalMax", "batteryImpact")
    if not isinstance(resources, dict) or any(key not in resources for key in resource_keys):
        raise ReceiptError(f"{label}.resources is incomplete")
    peak = number(resources["peakMemoryBytes"], f"{label}.resources.peakMemoryBytes", positive=True)
    ceiling = number(resources["memoryCeilingBytes"], f"{label}.resources.memoryCeilingBytes", positive=True)
    if peak >= ceiling:
        raise ReceiptError(f"{label}.resources peak memory does not stay below the measured ceiling")
    for key in ("thermalBefore", "thermalAfter", "thermalMax"):
        if resources[key] not in {"nominal", "fair"}:
            raise ReceiptError(f"{label}.resources.{key} is unsafe or unmeasured")
    battery = resources["batteryImpact"]
    battery_keys = ("levelBefore", "levelAfter", "isMonitoringEnabled", "measurementStatus")
    if not isinstance(battery, dict) or any(key not in battery for key in battery_keys):
        raise ReceiptError(f"{label}.resources.batteryImpact is incomplete")
    if battery["isMonitoringEnabled"] is not True or battery["measurementStatus"] != "measured":
        raise ReceiptError(f"{label}.resources battery impact was not measured")
    fraction(battery["levelBefore"], f"{label}.resources.batteryImpact.levelBefore")
    fraction(battery["levelAfter"], f"{label}.resources.batteryImpact.levelAfter")

    lifecycle = receipt.get("lifecycle")
    lifecycle_keys = ("backgroundForegroundOutcome", "memoryWarningOutcome", "unloadOutcome", "activeGenerationCountAfterRun")
    if not isinstance(lifecycle, dict) or any(key not in lifecycle for key in lifecycle_keys):
        raise ReceiptError(f"{label}.lifecycle is incomplete")
    for key in ("backgroundForegroundOutcome", "memoryWarningOutcome", "unloadOutcome"):
        passed(lifecycle[key], f"{label}.lifecycle.{key}")
    if nonnegative_integer(lifecycle["activeGenerationCountAfterRun"], f"{label}.lifecycle.activeGenerationCountAfterRun") != 0:
        raise ReceiptError(f"{label}.lifecycle left an active generation")

    cancellation = receipt.get("cancellation")
    cancellation_keys = ("prefillOutcome", "decodeOutcome", "cancellationLatency", "leaseReleased", "unloadOutcome")
    if not isinstance(cancellation, dict) or any(key not in cancellation for key in cancellation_keys):
        raise ReceiptError(f"{label}.cancellation is incomplete")
    passed(cancellation["prefillOutcome"], f"{label}.cancellation.prefillOutcome")
    passed(cancellation["decodeOutcome"], f"{label}.cancellation.decodeOutcome")
    passed(cancellation["unloadOutcome"], f"{label}.cancellation.unloadOutcome")
    number(cancellation["cancellationLatency"], f"{label}.cancellation.cancellationLatency")
    if cancellation["leaseReleased"] is not True:
        raise ReceiptError(f"{label}.cancellation did not release the generation lease")
    if quality["score"] < 0.7 or passed_cases == 0:
        raise ReceiptError(f"{label}.quality does not meet the admission threshold")
    if not run_id:
        raise ReceiptError(f"{label}.runID is empty")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--physical-receipt", required=True, type=Path)
    parser.add_argument("--coreai-receipt", required=True, type=Path)
    args = parser.parse_args()
    try:
        physical = load(args.physical_receipt, "physical")
        coreai = load(args.coreai_receipt, "Core AI")
        validate_receipt(physical, "physical")
        validate_receipt(coreai, "Core AI")
        if physical["runID"] != coreai["runID"]:
            raise ReceiptError("physical and Core AI receipts do not share a runID")
        if physical["sourceCommit"] != coreai["sourceCommit"]:
            raise ReceiptError("physical and Core AI receipts do not share a sourceCommit")
        if physical["build"]["appSHA256"] != coreai["build"]["appSHA256"]:
            raise ReceiptError("physical and Core AI build app hashes differ")
        if physical["artifactHashes"]["appSHA256"] != coreai["artifactHashes"]["appSHA256"]:
            raise ReceiptError("physical and Core AI app hashes differ")
        if physical["artifactHashes"]["corpusSHA256"] != coreai["artifactHashes"]["corpusSHA256"]:
            raise ReceiptError("physical and Core AI corpus hashes differ")
        if physical["device"]["osDeviceIdentifier"] != coreai["device"]["osDeviceIdentifier"]:
            raise ReceiptError("physical and Core AI receipts do not identify the same device")
        if "core" not in str(coreai["engine"]["type"]).lower() or "ai" not in str(coreai["engine"]["type"]).lower():
            raise ReceiptError("Core AI receipt engine.type is not Core AI")
    except ReceiptError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 65
    print(f"PASS: physical/Core AI receipts admitted for run {physical['runID']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
