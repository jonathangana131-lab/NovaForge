#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/validate-local-ai-receipts.py"
DIGEST = "sha256:" + "a" * 64


def receipt(engine_type="llamaCpp", execution_class="physical"):
    def load_attempt(resident_before: bool):
        return {
            "attempted": True,
            "available": True,
            "startedAt": "2026-08-27T00:00:00Z",
            "completedAt": "2026-08-27T00:00:01Z",
            "durationSeconds": 1,
            "modelResidentBefore": resident_before,
            "modelResidentAfter": True,
            "reason": "measured",
        }

    return {
        "schemaVersion": 2,
        "receiptKind": "local_ai_evaluation",
        "receiptID": "receipt-1",
        "runID": "run-1",
        "recordedAt": "2026-08-27T00:00:00Z",
        "sourceCommit": "a" * 40,
        "executionClass": execution_class,
        "availability": "verified",
        "claimsAllowed": True,
        "device": {"rawModelIdentifier": "iPhone17,1", "displayName": "iPhone", "osDeviceIdentifier": "device-1", "architecture": "arm64", "isSimulator": False, "isPhysicalDevice": True},
        "model": {"id": "Qwen/test", "immutableRevision": "b" * 40, "quantization": "Q4_K_M", "artifactSHA256": DIGEST, "artifactBytes": 1},
        "operatingSystem": {"name": "iOS", "version": "27.0", "build": "21A"},
        "build": {"sourceCommit": "a" * 40, "appVersion": "1.0", "buildNumber": "1", "configuration": "Release", "sdk": "iPhoneOS27.0", "xcode": "27.0", "appSHA256": DIGEST},
        "engine": {"type": engine_type, "engineRevision": "c" * 40, "backend": "cpu", "wrapperRevision": "d" * 40, "executionLocation": "device", "supportedHardware": "A17 Pro"},
        "generation": {"contextTokens": 1024, "maximumOutputTokens": 128},
        "sampling": {"temperature": 0, "topP": 1, "topK": 0, "minP": 0, "seed": 0, "repetitionPenalty": None},
        "load": {"cold": load_attempt(False), "warm": load_attempt(True), "postUnloadRecovery": load_attempt(False)},
        "performance": {"promptTokensPerSecond": 100, "timeToFirstTokenSeconds": 0.1, "decodeTokensPerSecond": 10, "usefulTokens": 128, "totalDurationSeconds": 13},
        "resources": {"peakMemoryBytes": 1_000_000_000, "memoryCeilingBytes": 2_000_000_000, "thermalBefore": "nominal", "thermalAfter": "fair", "thermalMax": "fair", "batteryImpact": {"levelBefore": 1, "levelAfter": 0.98, "isMonitoringEnabled": True, "measurementStatus": "measured"}},
        "lifecycle": {"backgroundForegroundOutcome": "pass", "memoryWarningOutcome": "pass", "unloadOutcome": "pass", "activeGenerationCountAfterRun": 0},
        "cancellation": {"prefillOutcome": "pass", "decodeOutcome": "pass", "cancellationLatency": 1, "leaseReleased": True, "unloadOutcome": "pass"},
        "artifactHashes": {"appSHA256": DIGEST, "modelSHA256": DIGEST, "corpusSHA256": DIGEST, "aotAssetSHA256": DIGEST},
        "quality": {"corpusID": "LocalAI2Corpus.v1", "corpusSHA256": DIGEST, "passedCaseCount": 1, "totalCaseCount": 1, "score": 1, "failureReasons": [], "perCaseResults": [{}]},
    }


def run(physical: Path, coreai: Path) -> int:
    return subprocess.run([sys.executable, str(GATE), "--physical-receipt", str(physical), "--coreai-receipt", str(coreai)]).returncode


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    physical = root / "physical.json"
    coreai = root / "coreai.json"
    assert run(physical, coreai) != 0, "missing receipts must fail closed"
    physical.write_text(json.dumps(receipt()), encoding="utf-8")
    coreai.write_text(json.dumps(receipt("coreAI")), encoding="utf-8")
    assert run(physical, coreai) == 0, "matching physical/Core AI receipts should pass"
    generic = receipt("coreAI", "generic_build")
    coreai.write_text(json.dumps(generic), encoding="utf-8")
    assert run(physical, coreai) != 0, "generic evidence must not pass as Core AI"
    for field, value in (
        (("performance", "usefulTokens"), 127),
        (("resources", "peakMemoryBytes"), 3_000_000_000),
        (("resources", "thermalMax"), "serious"),
        (("lifecycle", "backgroundForegroundOutcome"), "failed"),
        (("cancellation", "leaseReleased"), False),
    ):
        rejected = receipt("coreAI")
        rejected[field[0]][field[1]] = value
        coreai.write_text(json.dumps(rejected), encoding="utf-8")
        assert run(physical, coreai) != 0, f"unsafe {'.'.join(field)} evidence must fail closed"
print("PASS: local AI receipt gate fails closed for absent/generic evidence.")
