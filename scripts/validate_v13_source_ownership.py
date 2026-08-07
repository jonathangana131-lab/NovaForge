#!/usr/bin/env python3
"""Validate NovaForge V13 source-of-truth ownership map.

Zero third-party dependencies by design. This is an architecture safety gate,
not a style checker: it prevents the generational rewrite from promoting legacy
views or mixed app/runtime owners into new V13 source-of-truth boundaries.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

SHA_RE = re.compile(r"^[0-9a-f]{40}$")

REQUIRED_MODULE_IDS = {
    "AppShell", "ForgeProjects", "ForgeMission", "AgentCore", "AgentPolicy",
    "AgentTools", "ProviderRuntime", "ModelCatalog", "ModelRuntime",
    "ForgeRuntime", "RuntimeBridge", "ProjectStore", "ProjectBrain",
    "ProjectHistory", "ProjectTesting", "VisualQA", "DesignSystem",
    "ExecutionWorkers",
}

REQUIRED_FOUNDATION_IDS = {
    "harness-domain", "harness-engine", "harness-policy", "harness-providers",
    "harness-store", "harness-tools", "harness-transport",
    "provider-integration", "local-model-runtime", "provider-keychain",
    "approval-signing-authority", "workspace-checkpoint-boundary",
    "run-ownership-ledger", "launch-persistence",
}

REQUIRED_ADAPTER_IDS = {"legacy-agent-runtime", "legacy-app-composition"}

REQUIRED_HOTSPOT_IDS = {
    "app-root", "forge-chat-surface", "artifact-preview-runtime",
    "workspace-files-surface", "project-dashboard-surface",
    "history-runs-surface", "control-settings-surface", "terminal-surface",
    "legacy-glass-controls",
}

ALLOWED_PATH_KINDS = {"file", "directory"}


class ContractError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def substantive(value: Any, label: str) -> str:
    require(isinstance(value, str) and len(value.strip()) >= 30,
            f"{label} must be a substantive string")
    return value


def validate_sources(entry: dict[str, Any], label: str) -> None:
    sources = entry.get("sources")
    require(isinstance(sources, list) and sources, f"{label}.sources must be non-empty")
    for index, source in enumerate(sources):
        require(isinstance(source, dict), f"{label}.sources[{index}] must be an object")
        path = source.get("path")
        kind = source.get("pathKind")
        require(isinstance(path, str) and path.strip(), f"{label}.sources[{index}].path is required")
        require(not path.startswith("/") and ".." not in Path(path).parts,
                f"{label}.sources[{index}].path must be repository-relative and traversal-free")
        require(kind in ALLOWED_PATH_KINDS,
                f"{label}.sources[{index}].pathKind must be file or directory")
        if "observedBytes" in source:
            observed = source["observedBytes"]
            require(kind == "file", f"{label}.sources[{index}]: observedBytes only applies to files")
            require(isinstance(observed, int) and observed > 0,
                    f"{label}.sources[{index}].observedBytes must be a positive integer")


def validate_owned_entries(
    entries: Any,
    section: str,
    module_ids: set[str],
    expected_ids: set[str],
    allowed_dispositions: set[str],
) -> dict[str, dict[str, Any]]:
    require(isinstance(entries, list) and entries, f"{section} must be a non-empty array")
    seen: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(entries):
        label = f"{section}[{index}]"
        require(isinstance(entry, dict), f"{label} must be an object")
        entry_id = entry.get("id")
        require(isinstance(entry_id, str) and entry_id.strip(), f"{label}.id is required")
        require(entry_id not in seen, f"{section}: duplicate id {entry_id!r}")
        seen[entry_id] = entry
        disposition = entry.get("disposition")
        require(disposition in allowed_dispositions,
                f"{entry_id}: disposition {disposition!r} is not allowed in {section}")
        destinations = entry.get("destinations")
        require(isinstance(destinations, list) and destinations,
                f"{entry_id}: destinations must be non-empty")
        unknown = set(destinations) - module_ids
        require(not unknown, f"{entry_id}: unknown destination modules {sorted(unknown)}")
        validate_sources(entry, entry_id)
        substantive(entry.get("replacementGate"), f"{entry_id}.replacementGate")

    missing = expected_ids - set(seen)
    require(not missing, f"{section}: required entries silently dropped: {sorted(missing)}")
    return seen


def validate_contract(document: dict[str, Any]) -> None:
    require(document.get("formatVersion") == 1, "formatVersion must be 1")
    require(document.get("protocol") == "NF-SWARM-v13", "protocol must be NF-SWARM-v13")
    require(isinstance(document.get("sourceCommit"), str) and SHA_RE.fullmatch(document["sourceCommit"]) is not None,
            "sourceCommit must be an exact lowercase 40-character Git SHA")
    require(isinstance(document.get("parentMigrationContractHead"), str)
            and SHA_RE.fullmatch(document["parentMigrationContractHead"]) is not None,
            "parentMigrationContractHead must be an exact lowercase 40-character Git SHA")
    substantive(document.get("purpose"), "purpose")

    modules = document.get("destinationModules")
    require(isinstance(modules, list) and modules, "destinationModules must be non-empty")
    module_ids: list[str] = []
    for index, module in enumerate(modules):
        require(isinstance(module, dict), f"destinationModules[{index}] must be an object")
        module_id = module.get("id")
        require(isinstance(module_id, str) and module_id.strip(),
                f"destinationModules[{index}].id is required")
        module_ids.append(module_id)
        substantive(module.get("responsibility"), f"{module_id}.responsibility")
    require(len(module_ids) == len(set(module_ids)), "destinationModules ids must be unique")
    missing_modules = REQUIRED_MODULE_IDS - set(module_ids)
    require(not missing_modules, f"required destination modules silently dropped: {sorted(missing_modules)}")
    module_id_set = set(module_ids)

    foundations = validate_owned_entries(
        document.get("preservedFoundations"),
        "preservedFoundations",
        module_id_set,
        REQUIRED_FOUNDATION_IDS,
        {"preserve", "preserve_then_extract"},
    )
    adapters = validate_owned_entries(
        document.get("transitionalAdapters"),
        "transitionalAdapters",
        module_id_set,
        REQUIRED_ADAPTER_IDS,
        {"decompose_behind_adapter"},
    )
    hotspots = validate_owned_entries(
        document.get("legacyHotspots"),
        "legacyHotspots",
        module_id_set,
        REQUIRED_HOTSPOT_IDS,
        {"replace_behind_seam", "mine_then_replace"},
    )

    for entry_id, entry in foundations.items():
        substantive(entry.get("truth"), f"{entry_id}.truth")
        for source in entry["sources"]:
            require(not source["path"].startswith("AgentPad/Views/"),
                    f"{entry_id}: legacy View source cannot be a preserved foundation")

    for entry_id, entry in adapters.items():
        responsibilities = entry.get("currentResponsibilities")
        prohibited = entry.get("prohibitedInheritance")
        require(isinstance(responsibilities, list) and responsibilities,
                f"{entry_id}: currentResponsibilities must be non-empty")
        require(isinstance(prohibited, list) and prohibited,
                f"{entry_id}: prohibitedInheritance must be non-empty")
        require(all(isinstance(item, str) and len(item.strip()) >= 8 for item in responsibilities),
                f"{entry_id}: currentResponsibilities entries are too weak")
        require(all(isinstance(item, str) and len(item.strip()) >= 20 for item in prohibited),
                f"{entry_id}: prohibitedInheritance entries are too weak")

    for entry_id, entry in hotspots.items():
        substantive(entry.get("why"), f"{entry_id}.why")

    app_root = hotspots["app-root"]
    require(app_root["disposition"] == "replace_behind_seam",
            "app-root must be replaced behind a seam")
    require("AppShell" in app_root["destinations"],
            "app-root replacement must establish AppShell ownership")

    agent_runtime = adapters["legacy-agent-runtime"]
    require(agent_runtime["disposition"] == "decompose_behind_adapter",
            "legacy-agent-runtime must decompose behind an adapter")
    require("ForgeMission" in agent_runtime["destinations"],
            "legacy-agent-runtime decomposition must establish ForgeMission ownership")

    require("AgentPolicy" in foundations["harness-policy"]["destinations"],
            "harness-policy must remain owned by AgentPolicy")
    require("ProviderRuntime" in foundations["provider-integration"]["destinations"],
            "provider integration must route to ProviderRuntime")
    require({"ModelCatalog", "ModelRuntime"} <= set(foundations["local-model-runtime"]["destinations"]),
            "local model runtime must split catalog and execution ownership")
    require("ProjectStore" in foundations["launch-persistence"]["destinations"],
            "launch persistence must transition to ProjectStore")

    seams = document.get("replacementSeams")
    require(isinstance(seams, list) and len(seams) >= 6,
            "replacementSeams must define the staged controlled rewrite")
    seam_ids: list[str] = []
    orders: list[int] = []
    for index, seam in enumerate(seams):
        require(isinstance(seam, dict), f"replacementSeams[{index}] must be an object")
        seam_id = seam.get("id")
        require(isinstance(seam_id, str) and seam_id.strip(), f"replacementSeams[{index}].id is required")
        seam_ids.append(seam_id)
        order = seam.get("order")
        require(isinstance(order, int) and order >= 0, f"{seam_id}.order must be a non-negative integer")
        orders.append(order)
        owners = seam.get("owners")
        require(isinstance(owners, list) and owners, f"{seam_id}.owners must be non-empty")
        unknown = set(owners) - module_id_set
        require(not unknown, f"{seam_id}: unknown owner modules {sorted(unknown)}")
        substantive(seam.get("gate"), f"{seam_id}.gate")
    require(len(seam_ids) == len(set(seam_ids)), "replacementSeams ids must be unique")
    require(orders == sorted(orders) and len(orders) == len(set(orders)),
            "replacementSeams order must be strictly increasing")
    require(seam_ids[0] == "truth-contracts",
            "first replacement seam must keep truth contracts ahead of source deletion")
    require(seam_ids[-1] == "legacy-retirement",
            "legacy retirement must be the final staged seam")

    rules = document.get("dependencyRules")
    require(isinstance(rules, list) and len(rules) >= 8,
            "dependencyRules must encode the V13 ownership boundaries")
    require(all(isinstance(rule, str) and len(rule.strip()) >= 35 for rule in rules),
            "dependencyRules entries must be substantive")
    joined = "\n".join(rules)
    require("must not import AgentPad/Views" in joined,
            "dependencyRules must forbid new V13 truth ownership from legacy Views")
    require("independent of chat transcript" in joined,
            "dependencyRules must make mission identity independent of transcript")
    require("cannot directly reach provider credentials" in joined,
            "dependencyRules must isolate ForgeRuntime from secret authority")


def validate_source_files(document: dict[str, Any], repo_root: Path) -> None:
    require(repo_root.is_dir(), f"repo root is not a directory: {repo_root}")
    checked: set[tuple[str, str, int | None]] = set()
    for section in ("preservedFoundations", "transitionalAdapters", "legacyHotspots"):
        for entry in document[section]:
            for source in entry["sources"]:
                key = (source["path"], source["pathKind"], source.get("observedBytes"))
                if key in checked:
                    continue
                checked.add(key)
                path = repo_root / source["path"]
                if source["pathKind"] == "file":
                    require(path.is_file(), f"source file does not exist: {source['path']}")
                    if "observedBytes" in source:
                        actual = path.stat().st_size
                        require(actual == source["observedBytes"],
                                f"source snapshot drift for {source['path']}: expected {source['observedBytes']} bytes, found {actual}")
                else:
                    require(path.is_dir(), f"source directory does not exist: {source['path']}")


def run_self_tests(document: dict[str, Any]) -> None:
    cases: list[tuple[str, dict[str, Any]]] = []

    missing_policy = copy.deepcopy(document)
    missing_policy["preservedFoundations"] = [
        item for item in missing_policy["preservedFoundations"] if item["id"] != "harness-policy"
    ]
    cases.append(("policy foundation cannot disappear", missing_policy))

    preserve_root = copy.deepcopy(document)
    next(item for item in preserve_root["legacyHotspots"] if item["id"] == "app-root")["disposition"] = "preserve"
    cases.append(("AppRoot cannot become a preserved foundation by disposition", preserve_root))

    preserve_runtime = copy.deepcopy(document)
    next(item for item in preserve_runtime["transitionalAdapters"] if item["id"] == "legacy-agent-runtime")["disposition"] = "preserve"
    cases.append(("legacy AgentRuntime cannot become V13 ownership", preserve_runtime))

    unknown_module = copy.deepcopy(document)
    next(item for item in unknown_module["legacyHotspots"] if item["id"] == "forge-chat-surface")["destinations"].append("LegacyChatCore")
    cases.append(("unknown destination module is rejected", unknown_module))

    view_foundation = copy.deepcopy(document)
    next(item for item in view_foundation["preservedFoundations"] if item["id"] == "harness-domain")["sources"][0]["path"] = "AgentPad/Views/AppRootView.swift"
    next(item for item in view_foundation["preservedFoundations"] if item["id"] == "harness-domain")["sources"][0]["pathKind"] = "file"
    cases.append(("legacy View cannot become a preserved foundation", view_foundation))

    duplicate_hotspot = copy.deepcopy(document)
    duplicate_hotspot["legacyHotspots"].append(copy.deepcopy(duplicate_hotspot["legacyHotspots"][0]))
    cases.append(("ownership ids must be unique", duplicate_hotspot))

    no_gate = copy.deepcopy(document)
    next(item for item in no_gate["legacyHotspots"] if item["id"] == "artifact-preview-runtime")["replacementGate"] = "later"
    cases.append(("replacement gates must be substantive", no_gate))

    bad_sha = copy.deepcopy(document)
    bad_sha["sourceCommit"] = "main"
    cases.append(("source map must be pinned to exact source commit", bad_sha))

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
        raise ContractError(f"cannot read source ownership map: {error}") from error
    require(isinstance(value, dict), "top-level source ownership map must be an object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "map",
        nargs="?",
        type=Path,
        default=Path("docs/architecture/novaforge-v13-source-ownership-map.json"),
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--repo-root",
        type=Path,
        help="also verify pinned source paths and observed file sizes against this checkout",
    )
    args = parser.parse_args()

    try:
        document = load(args.map)
        validate_contract(document)
        if args.repo_root is not None:
            validate_source_files(document, args.repo_root)
        if args.self_test:
            run_self_tests(document)
    except ContractError as error:
        print(f"V13 source ownership map INVALID: {error}", file=sys.stderr)
        return 1

    suffix = " + validator self-tests" if args.self_test else ""
    print(f"V13 source ownership map valid{suffix}: {args.map}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
