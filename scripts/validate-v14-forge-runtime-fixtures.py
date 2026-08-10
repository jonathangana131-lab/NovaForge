#!/usr/bin/env python3
"""Validate NovaForge V14 generated-project fixtures without granting runtime authority."""
from __future__ import annotations

import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = ROOT / "Fixtures" / "ForgeRuntime" / "V14"
EXPECTED = {
    "focus-notes": {
        "projectID": "fixture.focus-notes",
        "controls": {"add-task", "complete-next", "clear-completed"},
        "textInputs": {"task-title"},
        "actions": set(),
        "gestures": set(),
    },
    "vector-drift": {
        "projectID": "fixture.vector-drift",
        "controls": {"start-run", "restart-run", "move-up", "move-down", "move-left", "move-right"},
        "textInputs": set(),
        "actions": {"move-x", "move-y"},
        "gestures": {"playfield"},
    },
}
ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
SEMANTIC_ID = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")
FORBIDDEN_NETWORK = re.compile(r"(?:https?://|\bfetch\s*\(|\bXMLHttpRequest\b|\bWebSocket\b)", re.I)


class FixtureHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.semantics = {"control": [], "text-input": [], "action": [], "gesture": []}
        self.has_main = False
        self.has_live_region = False
        self.has_viewport = False
        self.lang = ""
        self.inline_scripts: list[str] = []
        self._in_script = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "html": self.lang = values.get("lang") or ""
        if tag == "main": self.has_main = True
        if values.get("aria-live") in {"polite", "assertive"}: self.has_live_region = True
        if tag == "meta" and values.get("name") == "viewport": self.has_viewport = True
        if tag == "script" and not values.get("src"): self._in_script = True
        for key in self.semantics:
            value = values.get(f"data-novaforge-{key}")
            if value is not None: self.semantics[key].append(value)

    def handle_endtag(self, tag: str) -> None:
        if tag == "script": self._in_script = False

    def handle_data(self, data: str) -> None:
        if self._in_script: self.inline_scripts.append(data)


class ValidationError(Exception):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def validate_manifest(path: Path, expected_project_id: str) -> dict:
    try: payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc: fail(f"{path}: invalid JSON: {exc}")
    for key in ("formatVersion", "projectID", "projectVersion", "runtimeVersion", "entryPoint", "display", "presentation", "storage", "capabilities", "network", "bundledAssets", "modules"):
        if key not in payload: fail(f"{path}: missing {key}")
    if payload["formatVersion"] != {"major": 1, "minor": 0}: fail(f"{path}: manifest must target 1.0")
    if payload["runtimeVersion"] != {"major": 1, "minor": 0}: fail(f"{path}: runtime must target 1.0")
    if payload["projectID"] != expected_project_id or not ID.fullmatch(payload["projectID"]): fail(f"{path}: projectID mismatch/invalid")
    revision = payload["projectVersion"]
    if not isinstance(revision, str) or not revision or len(revision.encode()) > 64 or revision.strip() != revision: fail(f"{path}: projectVersion must be canonical and bounded")
    if payload["entryPoint"] != "index.html": fail(f"{path}: entryPoint must be index.html")
    if payload["storage"].get("namespace") != expected_project_id: fail(f"{path}: storage namespace must bind exact projectID")
    quota = payload["storage"].get("quotaBytes")
    if not isinstance(quota, int) or not 1 <= quota <= 64 * 1024 * 1024: fail(f"{path}: storage quota out of current host bounds")
    if payload["network"] != {"mode": "denied", "allowedHosts": []}: fail(f"{path}: representative fixture must be external-network denied")
    if payload["capabilities"] or payload["modules"] or payload["bundledAssets"]: fail(f"{path}: baseline fixture must not request ambient host capability/module/asset authority")
    if payload["presentation"].get("orientation") not in {"portrait", "landscape", "automatic"}: fail(f"{path}: unsupported baseline orientation")
    if payload["presentation"].get("viewport") not in {"safeArea", "edgeToEdge"}: fail(f"{path}: invalid viewport policy")
    return payload


def validate_html(path: Path, expected: dict) -> FixtureHTMLParser:
    text = path.read_text(encoding="utf-8")
    if FORBIDDEN_NETWORK.search(text): fail(f"{path}: external-network primitive/reference found")
    parser = FixtureHTMLParser(); parser.feed(text)
    if parser.lang != "en": fail(f"{path}: html lang must be en")
    if not parser.has_viewport: fail(f"{path}: viewport metadata missing")
    if not parser.has_main: fail(f"{path}: semantic main region missing")
    if not parser.has_live_region: fail(f"{path}: status live region missing")
    semantic_map = {
        "control": expected["controls"],
        "text-input": expected["textInputs"],
        "action": expected["actions"],
        "gesture": expected["gestures"],
    }
    for key, expected_values in semantic_map.items():
        actual = parser.semantics[key]
        if len(actual) != len(set(actual)): fail(f"{path}: duplicate data-novaforge-{key} identifier")
        if set(actual) != expected_values: fail(f"{path}: data-novaforge-{key} IDs {set(actual)!r} != {expected_values!r}")
        for value in actual:
            if not SEMANTIC_ID.fullmatch(value): fail(f"{path}: invalid semantic identifier {value!r}")
    if not parser.inline_scripts or not "use strict" in "\n".join(parser.inline_scripts): fail(f"{path}: deterministic inline script missing strict mode")
    return parser


def validate_all(root: Path = FIXTURE_ROOT) -> list[str]:
    discovered = {p.name for p in root.iterdir() if p.is_dir()} if root.exists() else set()
    if discovered != set(EXPECTED): fail(f"{root}: fixture set {discovered!r} != {set(EXPECTED)!r}")
    checked = []
    revisions = set()
    for name, expected in EXPECTED.items():
        directory = root / name
        manifest = validate_manifest(directory / "novaforge.runtime.json", expected["projectID"])
        if manifest["projectVersion"] in revisions: fail(f"{directory}: projectVersion must be unique across fixtures")
        revisions.add(manifest["projectVersion"])
        validate_html(directory / "index.html", expected)
        checked.append(name)
    return checked


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=FIXTURE_ROOT)
    args = parser.parse_args()
    try: checked = validate_all(args.root)
    except (ValidationError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr); return 1
    print(f"PASS: validated {len(checked)} V14 Forge Runtime fixtures: {', '.join(checked)}")
    print("Truth boundary: fixture validity is structural only; it is not launch/playtest/visual/device/completion evidence.")
    return 0


if __name__ == "__main__": raise SystemExit(main())
