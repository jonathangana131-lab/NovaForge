#!/usr/bin/env python3
"""Fail CI if the pre-2.0 Preview effort control loses its five-stop Ultra contract."""

from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPOSER = ROOT / "AgentPad/Views/ChatComposer.swift"


def fail(message: str) -> None:
    print(f"Preview effort contract failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    source = COMPOSER.read_text(encoding="utf-8")

    level_match = re.search(
        r"private enum Level:.*?\{(?P<body>.*?)\n\s*var id:",
        source,
        re.DOTALL,
    )
    if level_match is None:
        fail("ComposerReasoningPicker.Level was not found")

    cases = re.findall(
        r"^\s*case\s+([A-Za-z]\w*)\s*$",
        level_match.group("body"),
        re.MULTILINE,
    )
    expected = ["low", "medium", "high", "extraHigh", "ultraCode"]
    if cases != expected:
        fail(f"expected five ordered stops {expected}, found {cases}")

    title_match = re.search(
        r"var title: String\s*\{(?P<body>.*?)\n\s*\}",
        source,
        re.DOTALL,
    )
    if title_match is None or 'case .ultraCode: "Ultra"' not in title_match.group("body"):
        fail("terminal stop must be presented to the user as Ultra")

    if not re.search(
        r"case \.ultraCode:\s*"
        r"preferences\.reasoningEffort = \.max\s*"
        r"preferences\.orchestrationMode = \.ultraCode",
        source,
        re.DOTALL,
    ):
        fail("Ultra must still bind max reasoning to the isolated ultraCode orchestration path")

    if not re.search(
        r"if preferences\.orchestrationMode == \.ultra\s*\{.*?"
        r"preferences\.reasoningEffort = \.xhigh.*?"
        r"preferences\.orchestrationMode = \.standard",
        source,
        re.DOTALL,
    ):
        fail("legacy .ultra migration must remain distinct from the Preview Ultra stop")

    print("Preview effort contract passed: Low / Medium / High / Extra High / Ultra")


if __name__ == "__main__":
    main()
