#!/usr/bin/env python3
"""Fail closed unless Forge Compact is wired into NovaForge's real provider context.

This is intentionally a structural integration gate, not a performance claim. It
prevents Preview/release bookkeeping from counting ForgeCompactCore merely because
its standalone package exists. A passing result requires the app target to link the
package and the canonical provider-context preparer to build and consume a capsule.

Run from the repository root:
    python3 scripts/verify-forge-compact-provider-wiring.py
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "AgentPad.xcodeproj" / "project.pbxproj"
PREPARER = ROOT / "AgentPad" / "Services" / "AgentCanonicalContextPreparer.swift"
CORE_PACKAGE = ROOT / "Packages" / "ForgeCompactCore" / "Package.swift"


@dataclass(frozen=True)
class Check:
    label: str
    passed: bool
    detail: str


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"Forge Compact wiring gate could not read {path}: {error}") from error


def contains_all(text: str, needles: tuple[str, ...]) -> bool:
    return all(needle in text for needle in needles)


def check_project_link(project: str) -> Check:
    linked = contains_all(
        project,
        (
            'XCLocalSwiftPackageReference "Packages/ForgeCompactCore"',
            "relativePath = Packages/ForgeCompactCore;",
            "productName = ForgeCompactCore;",
        ),
    )
    return Check(
        "app target package link",
        linked,
        "AgentPad.xcodeproj must reference the local ForgeCompactCore package and product.",
    )


def check_core_package(package: str) -> Check:
    product_declared = bool(
        re.search(r"\.library\s*\(\s*name:\s*\"ForgeCompactCore\"", package)
    )
    return Check(
        "ForgeCompactCore product",
        product_declared,
        "Packages/ForgeCompactCore must publish the ForgeCompactCore library product.",
    )


def check_preparer_import(preparer: str) -> Check:
    imported = bool(re.search(r"(?m)^import\s+ForgeCompactCore\s*$", preparer))
    return Check(
        "canonical preparer import",
        imported,
        "AgentCanonicalContextPreparer.swift must import ForgeCompactCore directly.",
    )


def check_capsule_build(preparer: str) -> Check:
    builds = "ProjectCapsuleBuilder.build" in preparer
    return Check(
        "capsule construction",
        builds,
        "The canonical provider-context path must invoke ProjectCapsuleBuilder.build.",
    )


def check_capsule_consumption(preparer: str) -> Check:
    # Building a capsule and then ignoring it is not integration. Require the
    # provider-bound context path to consume the capsule's bounded render.
    consumes = bool(
        re.search(
            r"(?:capsule|projectCapsule)[\w.]*\.renderedContext|\.renderedContext",
            preparer,
        )
    )
    return Check(
        "provider-bound capsule consumption",
        consumes,
        "The provider supplement must consume ProjectCapsule.renderedContext.",
    )


def check_canonical_path_preserved(preparer: str) -> Check:
    # The integration is not allowed to replace canonical transcript/tool replay.
    # These anchors are the current safety boundary: modelItems still feed the
    # provider turn, and tool definitions are still forwarded independently.
    preserved = contains_all(
        preparer,
        (
            "state.modelItems",
            "tools: tools",
        ),
    )
    return Check(
        "canonical transcript/tool path preserved",
        preserved,
        "Forge Compact must supplement project memory, not replace modelItems or tool envelopes.",
    )


def main() -> int:
    missing_files = [path for path in (PROJECT, PREPARER, CORE_PACKAGE) if not path.is_file()]
    if missing_files:
        for path in missing_files:
            print(f"FAIL missing required path: {path.relative_to(ROOT)}")
        return 2

    project = read(PROJECT)
    preparer = read(PREPARER)
    package = read(CORE_PACKAGE)

    checks = (
        check_core_package(package),
        check_project_link(project),
        check_preparer_import(preparer),
        check_capsule_build(preparer),
        check_capsule_consumption(preparer),
        check_canonical_path_preserved(preparer),
    )

    failures = [check for check in checks if not check.passed]
    for check in checks:
        status = "PASS" if check.passed else "FAIL"
        print(f"{status} {check.label}: {check.detail}")

    if failures:
        print(
            f"\nForge Compact provider wiring: NOT INTEGRATED ({len(failures)} gate(s) failing)."
        )
        print(
            "Do not count Forge Compact as Preview-integrated until this gate passes and "
            "the normal build/test lane is green."
        )
        return 1

    print("\nForge Compact provider wiring: STRUCTURALLY INTEGRATED.")
    print(
        "This proves wiring only; it does not prove iPhone RAM savings, latency, thermal, "
        "energy, or task-quality improvements. Those require measured device evidence."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
