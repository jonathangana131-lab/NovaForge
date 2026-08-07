#!/usr/bin/env python3
"""Validate NovaForge V13's durable-data rewrite contract.

This intentionally has no third-party dependencies so it can run in local
preflight, CI, or migration-fixture jobs before Xcode is involved.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

SOURCE_SHA_RE = re.compile(r"^[0-9a-f]{40}$")

REQUIRED_STORE_IDS = {
    "swiftdata-primary",
    "swiftdata-compatibility",
    "swiftdata-recovery-snapshots",
    "agent-engine-run-index",
    "agent-policy-ledgers",
    "workspace-checkpoints",
    "user-workspaces",
    "keychain-credentials",
}

ALLOWED_DURABILITY = {
    "user_value",
    "continuation_evidence",
    "security_authority",
    "secret_authority",
    "auxiliary_state",
    "derived_cache",
}

ALLOWED_MIGRATION_MODES = {
    "migrate_losslessly",
    "preserve_until_reconciled",
    "preserve_in_place",
    "selective_migrate",
    "rebuild_from_source",
    "discardable",
}

PROTECTED_DURABILITY = {
    "user_value",
    "continuation_evidence",
    "security_authority",
    "secret_authority",
}

DISCARD_MODES = {"rebuild_from_source", "discardable"}

EXPECTED_PRE_EXPLICIT_V1_ENTITIES = {
    "AgentSettings",
    "ChatMessage",
    "Conversation",
    "Project",
    "ProjectArtifact",
    "ProjectEvent",
    "ProjectFileChange",
    "ProjectOSRun",
    "ProjectOSStep",
    "TerminalCommandRecord",
    "ToolRun",
}

EXPECTED_EXPLICIT_V1_ENTITIES = EXPECTED_PRE_EXPLICIT_V1_ENTITIES | {
    "AgentRunRecord",
    "ToolOperationRecord",
}


class ContractError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def validate_evidence(store: dict[str, Any]) -> None:
    evidence = store.get("sourceEvidence")
    require(isinstance(evidence, list) and evidence, f"{store['id']}: sourceEvidence must be non-empty")
    owners = set(store["sourceOwners"])
    for index, item in enumerate(evidence):
        require(isinstance(item, dict), f"{store['id']}: sourceEvidence[{index}] must be an object")
        path = item.get("repositoryPath")
        fact = item.get("fact")
        require(isinstance(path, str) and path in owners, f"{store['id']}: evidence path must be one of sourceOwners")
        require(isinstance(fact, str) and len(fact.strip()) >= 20, f"{store['id']}: evidence fact is too weak/empty")


def validate_contract(document: dict[str, Any]) -> None:
    require(document.get("formatVersion") == 1, "formatVersion must be 1")
    require(document.get("protocol") == "NF-SWARM-v13", "protocol must be NF-SWARM-v13")
    source_commit = document.get("sourceCommit")
    require(isinstance(source_commit, str) and SOURCE_SHA_RE.fullmatch(source_commit) is not None,
            "sourceCommit must be an exact lowercase 40-character Git SHA")

    signatures = document.get("legacySwiftDataSignatures")
    require(isinstance(signatures, dict), "legacySwiftDataSignatures must be an object")
    pre_v1 = signatures.get("preExplicitSchemaV1", {})
    explicit_v1 = signatures.get("explicitSchemaV1", {})
    require(set(pre_v1.get("entities", [])) == EXPECTED_PRE_EXPLICIT_V1_ENTITIES,
            "preExplicitSchemaV1 entity inventory no longer matches the released classifier")
    require(set(explicit_v1.get("entities", [])) == EXPECTED_EXPLICIT_V1_ENTITIES,
            "explicitSchemaV1 entity inventory no longer matches the released classifier")
    require(pre_v1.get("versionIdentifiers") == ["1.0.0"], "preExplicitSchemaV1 identifier must remain 1.0.0")
    require(explicit_v1.get("versionIdentifiers") == ["1.0.0"], "explicitSchemaV1 identifier must remain 1.0.0")
    require(pre_v1.get("classifierOwner") == "AgentPad/App/AgentPadApp.swift",
            "preExplicitSchemaV1 classifier owner changed without contract update")
    require(explicit_v1.get("classifierOwner") == "AgentPad/App/AgentPadApp.swift",
            "explicitSchemaV1 classifier owner changed without contract update")

    stores = document.get("stores")
    require(isinstance(stores, list) and stores, "stores must be a non-empty array")
    ids: list[str] = []
    by_id: dict[str, dict[str, Any]] = {}
    for index, store in enumerate(stores):
        require(isinstance(store, dict), f"stores[{index}] must be an object")
        store_id = store.get("id")
        require(isinstance(store_id, str) and store_id, f"stores[{index}].id must be non-empty")
        ids.append(store_id)
        by_id[store_id] = store

        durability = store.get("durability")
        mode = store.get("migrationMode")
        require(durability in ALLOWED_DURABILITY, f"{store_id}: unknown durability {durability!r}")
        require(mode in ALLOWED_MIGRATION_MODES, f"{store_id}: unknown migrationMode {mode!r}")
        if durability in PROTECTED_DURABILITY:
            require(mode not in DISCARD_MODES,
                    f"{store_id}: protected durability cannot use discard/rebuild migration")

        location = store.get("location")
        require(isinstance(location, str) and location.strip(), f"{store_id}: location is required")
        owners = store.get("sourceOwners")
        require(isinstance(owners, list) and owners, f"{store_id}: sourceOwners must be non-empty")
        require(all(isinstance(path, str) and path.startswith("AgentPad/") for path in owners),
                f"{store_id}: sourceOwners must be repository paths under AgentPad/")
        gates = store.get("requiredBeforeReplacement")
        require(isinstance(gates, list) and gates, f"{store_id}: requiredBeforeReplacement must be non-empty")
        require(all(isinstance(gate, str) and len(gate.strip()) >= 20 for gate in gates),
                f"{store_id}: replacement gates must be substantive")
        validate_evidence(store)

    require(len(ids) == len(set(ids)), "store ids must be unique")
    missing = REQUIRED_STORE_IDS - set(ids)
    require(not missing, f"required durable stores silently dropped: {sorted(missing)}")

    secret = by_id["keychain-credentials"]
    require(secret.get("durability") == "secret_authority", "keychain must remain secret_authority")
    require(secret.get("containsSecrets") is True, "keychain must declare containsSecrets=true")
    require(secret.get("plaintextMigration") is False, "keychain plaintextMigration must be false")
    require(secret.get("migrationMode") == "preserve_in_place", "keychain secret values must stay in place")
    require(secret.get("exportPolicy") == "never", "keychain exportPolicy must be never")
    require(secret.get("encryptionBoundary") == "keychain_this_device_only",
            "keychain encryption boundary must remain this-device-only")

    primary = by_id["swiftdata-primary"]
    require(primary.get("migrationMode") == "migrate_losslessly", "primary SwiftData store must migrate losslessly")
    require("NovaForge.store" in primary.get("location", ""), "primary SwiftData location lost NovaForge.store")

    compatibility = by_id["swiftdata-compatibility"]
    require(compatibility.get("migrationMode") == "preserve_until_reconciled",
            "compatibility store must remain authoritative until reconciliation")

    recovery = by_id["swiftdata-recovery-snapshots"]
    require(recovery.get("migrationMode") == "preserve_in_place",
            "verified recovery snapshots must not be rewritten in place")

    engine = by_id["agent-engine-run-index"]
    require("AgentEngine/v1/run-ownership-index.ledger" in engine.get("location", ""),
            "engine ownership ledger location changed without contract update")

    policy = by_id["agent-policy-ledgers"]
    require("policy-authority.ledger" in policy.get("location", "") and
            "mutation-effect-lifecycle.ledger" in policy.get("location", ""),
            "policy ledger location inventory is incomplete")

    checkpoints = by_id["workspace-checkpoints"]
    require("AgentPolicy/v1/checkpoints" in checkpoints.get("location", ""),
            "workspace checkpoint location changed without contract update")

    rules = document.get("rewriteRules")
    require(isinstance(rules, list) and len(rules) >= 4, "rewriteRules must preserve the core safety invariants")


def validate_source_files(document: dict[str, Any], repo_root: Path) -> None:
    require(repo_root.is_dir(), f"repo root is not a directory: {repo_root}")
    required_paths: set[str] = set()
    signatures = document["legacySwiftDataSignatures"]
    required_paths.add(signatures["preExplicitSchemaV1"]["classifierOwner"])
    required_paths.add(signatures["explicitSchemaV1"]["classifierOwner"])
    for store in document["stores"]:
        required_paths.update(store["sourceOwners"])
        required_paths.update(
            item["repositoryPath"] for item in store["sourceEvidence"]
        )

    missing = sorted(
        path for path in required_paths if not (repo_root / path).is_file()
    )
    require(not missing, f"source evidence paths do not exist: {missing}")


def run_self_tests(document: dict[str, Any]) -> None:
    cases: list[tuple[str, Any]] = []

    missing_keychain = copy.deepcopy(document)
    missing_keychain["stores"] = [s for s in missing_keychain["stores"] if s["id"] != "keychain-credentials"]
    cases.append(("required store cannot disappear", missing_keychain))

    plaintext_secret = copy.deepcopy(document)
    next(s for s in plaintext_secret["stores"] if s["id"] == "keychain-credentials")["plaintextMigration"] = True
    cases.append(("plaintext credential migration is rejected", plaintext_secret))

    discard_workspace = copy.deepcopy(document)
    next(s for s in discard_workspace["stores"] if s["id"] == "user-workspaces")["migrationMode"] = "discardable"
    cases.append(("user workspaces cannot become discardable", discard_workspace))

    legacy_signature_drift = copy.deepcopy(document)
    legacy_signature_drift["legacySwiftDataSignatures"]["preExplicitSchemaV1"]["entities"].pop()
    cases.append(("released legacy classifier inventory cannot drift silently", legacy_signature_drift))

    duplicate = copy.deepcopy(document)
    duplicate["stores"].append(copy.deepcopy(duplicate["stores"][0]))
    cases.append(("store ids must remain unique", duplicate))

    bad_sha = copy.deepcopy(document)
    bad_sha["sourceCommit"] = "main"
    cases.append(("contract is pinned to an exact source commit", bad_sha))

    failures: list[str] = []
    for name, candidate in cases:
        try:
            validate_contract(candidate)
        except ContractError:
            continue
        failures.append(name)

    if failures:
        raise ContractError("self-test did not reject invalid cases: " + ", ".join(failures))


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read migration contract: {error}") from error
    require(isinstance(value, dict), "top-level migration contract must be an object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "contract",
        nargs="?",
        type=Path,
        default=Path("docs/migration/novaforge-v13-durable-data-contract.json"),
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--repo-root",
        type=Path,
        help="also verify every source-owner/evidence path exists under this checkout",
    )
    args = parser.parse_args()

    try:
        document = load(args.contract)
        validate_contract(document)
        if args.repo_root is not None:
            validate_source_files(document, args.repo_root)
        if args.self_test:
            run_self_tests(document)
    except ContractError as error:
        print(f"V13 migration contract INVALID: {error}", file=sys.stderr)
        return 1

    suffix = " + validator self-tests" if args.self_test else ""
    print(f"V13 migration contract valid{suffix}: {args.contract}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
