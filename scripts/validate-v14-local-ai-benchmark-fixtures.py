#!/usr/bin/env python3
"""Validate and fingerprint the canonical NovaForge V14 Local AI benchmark fixture pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import sys
from dataclasses import dataclass
from typing import Any

SCHEMA_VERSION = 1
CATEGORIES = (
    "intentRouting",
    "structuredExtraction",
    "structuredToolUse",
    "repositoryNavigation",
    "codeRepair",
    "multiFileChange",
    "contextCompaction",
    "continuationRecovery",
)
REQUIRED_GENERAL_AGENT_CATEGORIES = {
    "intentRouting",
    "structuredToolUse",
    "repositoryNavigation",
    "codeRepair",
    "contextCompaction",
    "continuationRecovery",
}


class ValidationError(ValueError):
    pass


def _no_duplicate_object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValidationError(f"{path}: UTF-8 BOM is forbidden")
    if b"\r" in raw:
        raise ValidationError(f"{path}: CR/CRLF line endings are forbidden")
    if not raw.endswith(b"\n"):
        raise ValidationError(f"{path}: canonical JSON files must end with one LF")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{path}: invalid UTF-8") from exc
    try:
        value = json.loads(
            text,
            object_pairs_hook=_no_duplicate_object_pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(ValidationError(f"non-finite JSON constant forbidden: {token}")),
        )
    except (json.JSONDecodeError, ValidationError) as exc:
        raise ValidationError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{path}: root must be an object")
    canonical = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    if raw != canonical:
        raise ValidationError(f"{path}: JSON is not in canonical sorted/minified UTF-8 form")
    return value, raw


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValidationError(f"{label}: key mismatch missing={missing} extra={extra}")


def require_nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise ValidationError(f"{label}: expected trimmed non-empty string")
    return value


def require_relative_path(value: Any, label: str) -> pathlib.PurePosixPath:
    text = require_nonempty_string(value, label)
    path = pathlib.PurePosixPath(text)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ValidationError(f"{label}: path traversal/absolute path forbidden: {text}")
    if "\\" in text:
        raise ValidationError(f"{label}: backslashes forbidden: {text}")
    return path


def validate_workspace(workspace: Any, label: str) -> None:
    if not isinstance(workspace, list):
        raise ValidationError(f"{label}: workspace must be an array")
    seen: set[str] = set()
    for index, entry in enumerate(workspace):
        if not isinstance(entry, dict):
            raise ValidationError(f"{label}[{index}]: workspace entry must be an object")
        require_exact_keys(entry, {"content", "path"}, f"{label}[{index}]")
        path = str(require_relative_path(entry["path"], f"{label}[{index}].path"))
        if path in seen:
            raise ValidationError(f"{label}: duplicate workspace path: {path}")
        seen.add(path)
        if not isinstance(entry["content"], str):
            raise ValidationError(f"{label}[{index}].content: expected string")


def validate_expected(expected: Any, category: str, label: str) -> None:
    if not isinstance(expected, dict):
        raise ValidationError(f"{label}: expected must be an object")
    if not expected:
        raise ValidationError(f"{label}: expected must not be empty")
    # Require category-specific evidence shapes so a fixture cannot silently change task semantics.
    required_by_category = {
        "intentRouting": {"route"},
        "structuredExtraction": {"json"},
        "structuredToolUse": {"tool_calls"},
        "repositoryNavigation": {"paths"},
        "codeRepair": {"files"},
        "multiFileChange": {"files"},
        "contextCompaction": {"protected_facts", "resume_state"},
        "continuationRecovery": {"resume_from_checkpoint", "state"},
    }
    missing = required_by_category[category] - set(expected)
    if missing:
        raise ValidationError(f"{label}: missing category contract keys: {sorted(missing)}")


def validate_fixture(fixture: dict[str, Any], task: dict[str, Any], label: str) -> None:
    require_exact_keys(
        fixture,
        {"category", "expected", "instructions", "revision", "schema_version", "task_id", "workspace"},
        label,
    )
    if not isinstance(fixture["schema_version"], int) or isinstance(fixture["schema_version"], bool) or fixture["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"{label}: unsupported schema_version")
    if fixture["task_id"] != task["id"]:
        raise ValidationError(f"{label}: task_id mismatch")
    if not isinstance(fixture["revision"], int) or isinstance(fixture["revision"], bool) or fixture["revision"] <= 0:
        raise ValidationError(f"{label}: revision must be a positive integer")
    if fixture["revision"] != task["revision"]:
        raise ValidationError(f"{label}: revision mismatch")
    if fixture["category"] != task["category"]:
        raise ValidationError(f"{label}: category mismatch")
    require_nonempty_string(fixture["instructions"], f"{label}.instructions")
    validate_workspace(fixture["workspace"], f"{label}.workspace")
    validate_expected(fixture["expected"], fixture["category"], f"{label}.expected")


@dataclass(frozen=True)
class ValidationResult:
    suite_id: str
    suite_version: int
    task_count: int
    corpus_sha256: str
    task_digests: dict[str, str]
    suite_definition: dict[str, Any]


def validate(root: pathlib.Path) -> ValidationResult:
    root = root.resolve()
    manifest_path = root / "manifest.json"
    manifest, manifest_raw = load_json(manifest_path)
    require_exact_keys(
        manifest,
        {"fixture_set_id", "required_categories", "schema_version", "suite_id", "suite_version", "tasks"},
        "manifest",
    )
    if not isinstance(manifest["schema_version"], int) or isinstance(manifest["schema_version"], bool) or manifest["schema_version"] != SCHEMA_VERSION:
        raise ValidationError("manifest: unsupported schema_version")
    fixture_set_id = require_nonempty_string(manifest["fixture_set_id"], "manifest.fixture_set_id")
    if fixture_set_id != "novaforge.local-ai.general-agent-fixtures":
        raise ValidationError("manifest.fixture_set_id: unexpected fixture set")
    suite_id = require_nonempty_string(manifest["suite_id"], "manifest.suite_id")
    if suite_id != "novaforge.local-ai.general-agent":
        raise ValidationError("manifest.suite_id: unexpected suite id")
    suite_version = manifest["suite_version"]
    if not isinstance(suite_version, int) or isinstance(suite_version, bool) or suite_version != 1:
        raise ValidationError("manifest.suite_version: V1 fixture directory requires suite version 1")

    required_categories = manifest["required_categories"]
    if not isinstance(required_categories, list) or required_categories != sorted(REQUIRED_GENERAL_AGENT_CATEGORIES):
        raise ValidationError("manifest.required_categories: must exactly match sorted #108 general-agent categories")

    tasks = manifest["tasks"]
    if not isinstance(tasks, list) or not tasks:
        raise ValidationError("manifest.tasks: expected non-empty array")
    if len(tasks) != len(CATEGORIES):
        raise ValidationError("manifest.tasks: V1 must contain exactly one task for every V14 benchmark category")

    seen_ids: set[str] = set()
    seen_categories: set[str] = set()
    task_digests: dict[str, str] = {}
    corpus_records: list[str] = []
    ids_in_order: list[str] = []

    for index, task in enumerate(tasks):
        label = f"manifest.tasks[{index}]"
        if not isinstance(task, dict):
            raise ValidationError(f"{label}: expected object")
        require_exact_keys(task, {"category", "fixture_sha256", "id", "is_required", "path", "revision", "weight"}, label)
        task_id = require_nonempty_string(task["id"], f"{label}.id")
        ids_in_order.append(task_id)
        if task_id in seen_ids:
            raise ValidationError(f"{label}: duplicate task id {task_id}")
        seen_ids.add(task_id)
        revision = task["revision"]
        if not isinstance(revision, int) or isinstance(revision, bool) or revision <= 0:
            raise ValidationError(f"{label}.revision: expected positive integer")
        category = task["category"]
        if category not in CATEGORIES:
            raise ValidationError(f"{label}.category: unknown category {category}")
        if category in seen_categories:
            raise ValidationError(f"{label}: V1 requires one task per category; duplicate {category}")
        seen_categories.add(category)
        weight = task["weight"]
        if not isinstance(weight, (int, float)) or isinstance(weight, bool) or not math.isfinite(weight) or weight <= 0:
            raise ValidationError(f"{label}.weight: expected finite positive number")
        if not isinstance(task["is_required"], bool):
            raise ValidationError(f"{label}.is_required: expected boolean")
        expected_required = category in REQUIRED_GENERAL_AGENT_CATEGORIES
        if task["is_required"] != expected_required:
            raise ValidationError(
                f"{label}.is_required: suite v1 requires {str(expected_required).lower()} for category {category}"
            )
        digest = task["fixture_sha256"]
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValidationError(f"{label}.fixture_sha256: expected lowercase SHA-256")
        rel = require_relative_path(task["path"], f"{label}.path")
        if rel.parts[:1] != ("fixtures",) or rel.suffix != ".json":
            raise ValidationError(f"{label}.path: fixture must be a JSON file under fixtures/")
        fixture_path = (root / pathlib.Path(*rel.parts)).resolve()
        if root not in fixture_path.parents:
            raise ValidationError(f"{label}.path: resolved path escaped fixture root")
        fixture, fixture_raw = load_json(fixture_path)
        actual_digest = sha256(fixture_raw)
        if actual_digest != digest:
            raise ValidationError(f"{label}: fixture SHA-256 mismatch expected={digest} actual={actual_digest}")
        validate_fixture(fixture, task, str(rel))
        task_digests[task_id] = actual_digest
        corpus_records.append(f"{task_id}\0{revision}\0{category}\0{rel.as_posix()}\0{actual_digest}\n")

    if ids_in_order != sorted(ids_in_order):
        raise ValidationError("manifest.tasks: tasks must be sorted by id for deterministic identity")
    if seen_categories != set(CATEGORIES):
        raise ValidationError("manifest.tasks: category coverage mismatch")

    manifest_digest = sha256(manifest_raw)
    corpus_preimage = (
        f"novaforge-v14-local-ai-fixture-pack\0{SCHEMA_VERSION}\n"
        f"manifest\0{manifest_digest}\n" + "".join(corpus_records)
    ).encode("utf-8")
    suite_definition = {
        "id": suite_id,
        "version": suite_version,
        "requiredCategories": required_categories,
        "tasks": [
            {
                "id": task["id"],
                "revision": task["revision"],
                "category": task["category"],
                "weight": task["weight"],
                "isRequired": task["is_required"],
                "fixtureDigest": task["fixture_sha256"],
            }
            for task in tasks
        ],
    }
    return ValidationResult(
        suite_id=suite_id,
        suite_version=suite_version,
        task_count=len(tasks),
        corpus_sha256=sha256(corpus_preimage),
        task_digests=task_digests,
        suite_definition=suite_definition,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default="Benchmarks/LocalAI/v1")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument(
        "--suite-json",
        action="store_true",
        help="emit the validated LocalAIBenchmarkSuite Codable JSON shape from #108",
    )
    args = parser.parse_args()
    try:
        result = validate(pathlib.Path(args.root))
    except (OSError, ValidationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    payload = {
        "corpus_sha256": result.corpus_sha256,
        "suite_id": result.suite_id,
        "suite_version": result.suite_version,
        "task_count": result.task_count,
        "task_digests": dict(sorted(result.task_digests.items())),
    }
    if args.as_json and args.suite_json:
        parser.error("--json and --suite-json are mutually exclusive")
    if args.suite_json:
        print(json.dumps(result.suite_definition, sort_keys=True, separators=(",", ":")))
    elif args.as_json:
        print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    else:
        print(f"PASS {result.suite_id} v{result.suite_version} tasks={result.task_count} corpus_sha256={result.corpus_sha256}")
        for task_id, digest in sorted(result.task_digests.items()):
            print(f"{task_id} {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
