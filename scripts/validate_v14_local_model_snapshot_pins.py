#!/usr/bin/env python3
"""Fail closed when NovaForge MLX profiles load mutable Hugging Face snapshots.

This guard intentionally validates source shape rather than model compatibility.
It exists so a physical-device qualification receipt can be tied to immutable
model bytes/tokenizer/config instead of whichever commit `main` points at later.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

RUNTIME_PATH = Path(
    "Vendor/swift-llama-cpp/Sources/SwiftLlama/NovaForgeMLXRuntime.swift"
)
PROFILE_ENUM = "NovaForgeMLXProfile"
FULL_GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
RETURN_STRING_RE = re.compile(r'\breturn\s+"([^"]*)"')
CASE_RE = re.compile(r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\b")


class ValidationError(RuntimeError):
    pass


def _scan_balanced(source: str, opening_index: int, opener: str, closer: str) -> tuple[str, int]:
    if opening_index >= len(source) or source[opening_index] != opener:
        raise ValidationError(f"expected {opener!r} at offset {opening_index}")

    depth = 0
    i = opening_index
    state = "code"
    block_comment_depth = 0

    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""

        if state == "line_comment":
            if ch == "\n":
                state = "code"
            i += 1
            continue

        if state == "block_comment":
            if ch == "/" and nxt == "*":
                block_comment_depth += 1
                i += 2
                continue
            if ch == "*" and nxt == "/":
                block_comment_depth -= 1
                i += 2
                if block_comment_depth == 0:
                    state = "code"
                continue
            i += 1
            continue

        if state == "string":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue

        if state == "multiline_string":
            if source.startswith('"""', i):
                state = "code"
                i += 3
                continue
            i += 1
            continue

        if ch == "/" and nxt == "/":
            state = "line_comment"
            i += 2
            continue
        if ch == "/" and nxt == "*":
            state = "block_comment"
            block_comment_depth = 1
            i += 2
            continue
        if source.startswith('"""', i):
            state = "multiline_string"
            i += 3
            continue
        if ch == '"':
            state = "string"
            i += 1
            continue

        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return source[opening_index + 1 : i], i + 1
            if depth < 0:
                raise ValidationError(f"unbalanced {opener}{closer} pair")
        i += 1

    raise ValidationError(f"unterminated {opener}{closer} block")


def _extract_named_brace_body(source: str, declaration_pattern: re.Pattern[str], description: str) -> str:
    match = declaration_pattern.search(source)
    if match is None:
        raise ValidationError(f"missing {description}")
    brace_index = source.find("{", match.end())
    if brace_index == -1:
        raise ValidationError(f"missing body for {description}")
    body, _ = _scan_balanced(source, brace_index, "{", "}")
    return body


def _top_level_enum_cases(enum_body: str) -> list[str]:
    cases: list[str] = []
    depth = 0
    for line in enum_body.splitlines():
        if depth == 0:
            match = CASE_RE.match(line)
            if match is not None:
                cases.append(match.group(1))
        # Profile case declarations are simple; nested switch cases appear only
        # after opening a property/function body.
        depth += line.count("{") - line.count("}")
        if depth < 0:
            raise ValidationError("profile enum body has unbalanced braces")
    if depth != 0:
        raise ValidationError("profile enum body has unbalanced braces")
    return cases


def _model_configuration_calls(source: str) -> list[str]:
    calls: list[str] = []
    cursor = 0
    token = "ModelConfiguration"
    while True:
        index = source.find(token, cursor)
        if index == -1:
            break
        before = source[index - 1] if index > 0 else ""
        after_index = index + len(token)
        after = source[after_index] if after_index < len(source) else ""
        if (before and (before.isalnum() or before == "_")) or (
            after and (after.isalnum() or after == "_")
        ):
            cursor = after_index
            continue
        open_paren = after_index
        while open_paren < len(source) and source[open_paren].isspace():
            open_paren += 1
        if open_paren >= len(source) or source[open_paren] != "(":
            cursor = after_index
            continue
        body, end = _scan_balanced(source, open_paren, "(", ")")
        calls.append(body)
        cursor = end
    return calls


def validate_runtime_source(source: str, *, source_name: str = str(RUNTIME_PATH)) -> list[str]:
    enum_body = _extract_named_brace_body(
        source,
        re.compile(r"\b(?:public\s+)?enum\s+" + re.escape(PROFILE_ENUM) + r"\b"),
        f"{PROFILE_ENUM} enum",
    )
    profile_cases = _top_level_enum_cases(enum_body)
    if not profile_cases:
        raise ValidationError(f"{source_name}: {PROFILE_ENUM} declares no profiles")

    revision_body = _extract_named_brace_body(
        enum_body,
        re.compile(r"\b(?:public\s+)?var\s+revision\s*:\s*String\b"),
        f"{PROFILE_ENUM}.revision",
    )
    revision_literals = RETURN_STRING_RE.findall(revision_body)
    if len(revision_literals) != len(profile_cases):
        raise ValidationError(
            f"{source_name}: expected one literal immutable revision for each of "
            f"{len(profile_cases)} MLX profiles; found {len(revision_literals)}"
        )
    invalid_revisions = [value for value in revision_literals if FULL_GIT_SHA_RE.fullmatch(value) is None]
    if invalid_revisions:
        rendered = ", ".join(repr(value) for value in invalid_revisions)
        raise ValidationError(
            f"{source_name}: MLX revisions must be full 40-character lowercase Git SHAs; invalid: {rendered}"
        )

    calls = _model_configuration_calls(source)
    if not calls:
        raise ValidationError(f"{source_name}: no ModelConfiguration(...) call found")

    profile_load_calls = 0
    for call in calls:
        compact = re.sub(r"\s+", "", call)
        if "id:profile.repositoryID" not in compact:
            continue
        profile_load_calls += 1
        if "revision:profile.revision" not in compact:
            raise ValidationError(
                f"{source_name}: ModelConfiguration(id: profile.repositoryID, ...) must bind "
                "revision: profile.revision; mutable/default Hugging Face revisions are forbidden"
            )
    if profile_load_calls == 0:
        raise ValidationError(
            f"{source_name}: no profile-backed ModelConfiguration(id: profile.repositoryID, ...) load found"
        )

    return [
        f"{len(profile_cases)} MLX profiles expose full immutable revisions",
        f"{profile_load_calls} profile-backed ModelConfiguration load(s) bind profile.revision",
    ]


def validate_repo(repo_root: Path) -> list[str]:
    runtime = repo_root / RUNTIME_PATH
    if not runtime.is_file():
        return [
            f"{RUNTIME_PATH} is not present on this head; no MLX snapshot load exists to qualify yet"
        ]
    source = runtime.read_text(encoding="utf-8")
    return validate_runtime_source(source, source_name=str(runtime))


def _fixture_source(*, revisions: list[str], configuration: str) -> str:
    cases = ["nanbeige42Coder3Bit", "nanbeige42Coder2Bit"]
    switch_lines: list[str] = []
    for case, revision in zip(cases, revisions, strict=True):
        switch_lines.extend([f"        case .{case}:", f'            return "{revision}"'])
    return f'''import Foundation
public enum NovaForgeMLXProfile: String, CaseIterable, Sendable {{
    case nanbeige42Coder3Bit
    case nanbeige42Coder2Bit

    public var repositoryID: String {{
        switch self {{
        case .nanbeige42Coder3Bit: return "example/three-bit"
        case .nanbeige42Coder2Bit: return "example/two-bit"
        }}
    }}

    public var revision: String {{
        switch self {{
{chr(10).join(switch_lines)}
        }}
    }}
}}

public actor NovaForgeMLXRuntime {{
    private func container(for profile: NovaForgeMLXProfile) async throws {{
        let configuration = {configuration}
        _ = configuration
    }}
}}
'''


def run_self_test() -> list[str]:
    sha_a = "a" * 40
    sha_b = "b" * 40
    valid_source = _fixture_source(
        revisions=[sha_a, sha_b],
        configuration="ModelConfiguration(id: profile.repositoryID, revision: profile.revision)",
    )
    mutable_source = _fixture_source(
        revisions=[sha_a, sha_b],
        configuration="ModelConfiguration(id: profile.repositoryID)",
    )
    branch_revision_source = _fixture_source(
        revisions=["main", sha_b],
        configuration="ModelConfiguration(id: profile.repositoryID, revision: profile.revision)",
    )
    short_revision_source = _fixture_source(
        revisions=["abc1234", sha_b],
        configuration="ModelConfiguration(id: profile.repositoryID, revision: profile.revision)",
    )

    validate_runtime_source(valid_source, source_name="self-test-valid")

    for name, source in [
        ("mutable configuration", mutable_source),
        ("branch revision", branch_revision_source),
        ("short revision", short_revision_source),
    ]:
        try:
            validate_runtime_source(source, source_name=f"self-test-{name}")
        except ValidationError:
            pass
        else:
            raise ValidationError(f"self-test expected rejection for {name}")

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        result = validate_repo(root)
        if "not present" not in result[0]:
            raise ValidationError("self-test expected absent MLX runtime to pass without qualification")

    return [
        "valid full-SHA profile pin accepted",
        "mutable ModelConfiguration load rejected",
        "branch/short revision labels rejected",
        "head without MLX runtime remains valid",
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=".", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            for message in run_self_test():
                print(f"[PASS] self-test: {message}")
        for message in validate_repo(args.repo_root.resolve()):
            print(f"[PASS] {message}")
    except (OSError, UnicodeError, ValidationError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
