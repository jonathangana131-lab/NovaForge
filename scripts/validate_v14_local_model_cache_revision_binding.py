#!/usr/bin/env python3
"""Fail closed when NovaForge MLX cache identity drifts from profile.revision.

This validator complements validate_v14_local_model_snapshot_pins.py. The
snapshot-pin validator proves profile revisions are immutable full SHAs and that
generation-time ModelConfiguration loads bind profile.revision. This validator
proves the cache-only downloader and cached-snapshot lookup consume that same
revision authority rather than a different variable, alias, or mutable ref.
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


class ValidationError(RuntimeError):
    pass


def _scan_balanced(
    source: str,
    opening_index: int,
    opener: str,
    closer: str,
) -> tuple[str, int]:
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


def _extract_brace_body(source: str, marker: str, description: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise ValidationError(f"missing {description}: {marker}")
    brace = source.find("{", start + len(marker))
    if brace < 0:
        raise ValidationError(f"missing body for {description}")
    body, _ = _scan_balanced(source, brace, "{", "}")
    return body


def _call_bodies(source: str, token: str) -> list[str]:
    calls: list[str] = []
    cursor = 0
    while True:
        index = source.find(token, cursor)
        if index < 0:
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


def _compact(source: str) -> str:
    return re.sub(r"\s+", "", source)


def _download_revision_binding(download_body: str) -> str:
    """Return the non-optional local name bound directly from `revision`."""

    patterns = (
        re.compile(
            r"\bguard\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*revision\s+else\s*\{"
        ),
        re.compile(r"\bguard\s+let\s+(revision)\s+else\s*\{"),
    )
    matches: list[str] = []
    for pattern in patterns:
        matches.extend(match.group(1) for match in pattern.finditer(download_body))

    unique = sorted(set(matches))
    if len(unique) != 1:
        raise ValidationError(
            "NovaForgeCachedHubDownloader.download must bind its optional revision "
            "exactly once with a fail-closed guard before cache resolution"
        )
    return unique[0]


def _require_resolve_revision_refs(
    source: str,
    *,
    expected_ref: str,
    description: str,
) -> int:
    calls = _call_bodies(source, "resolveRevision")
    if not calls:
        raise ValidationError(f"{description} must call resolveRevision(...)")

    expected = f"ref:{expected_ref}"
    for call in calls:
        compact = _compact(call)
        if expected not in compact:
            raise ValidationError(
                f"{description} must bind every resolveRevision ref to "
                f"{expected_ref}; found resolveRevision({compact})"
            )
    return len(calls)


def validate_runtime_source(
    source: str,
    *,
    source_name: str = str(RUNTIME_PATH),
) -> list[str]:
    downloader = _extract_brace_body(
        source,
        "private struct NovaForgeCachedHubDownloader: Downloader",
        "NovaForgeCachedHubDownloader",
    )
    download = _extract_brace_body(
        downloader,
        "func download(",
        "NovaForgeCachedHubDownloader.download",
    )

    bound_revision = _download_revision_binding(download)
    downloader_calls = _require_resolve_revision_refs(
        download,
        expected_ref=bound_revision,
        description="NovaForgeCachedHubDownloader.download",
    )

    cached_snapshot = _extract_brace_body(
        source,
        "private static func cachedSnapshotURL(profile: NovaForgeMLXProfile) -> URL?",
        "cachedSnapshotURL(profile:)",
    )
    cached_calls = _require_resolve_revision_refs(
        cached_snapshot,
        expected_ref="profile.revision",
        description="cachedSnapshotURL(profile:)",
    )

    return [
        (
            f"{source_name}: cache-only downloader fail-closes optional revision "
            f"and binds {downloader_calls} resolveRevision call(s) to {bound_revision}"
        ),
        (
            f"{source_name}: cached snapshot lookup binds {cached_calls} "
            "resolveRevision call(s) to profile.revision"
        ),
    ]


def validate_repo(repo_root: Path) -> list[str]:
    runtime = repo_root / RUNTIME_PATH
    if not runtime.is_file():
        return [
            f"{RUNTIME_PATH} is not present on this head; no MLX cache revision binding exists to qualify yet"
        ]
    return validate_runtime_source(
        runtime.read_text(encoding="utf-8"),
        source_name=str(runtime),
    )


def _fixture_source(
    *,
    download_guard: str,
    download_ref: str,
    cached_ref: str,
) -> str:
    return f"""
private struct NovaForgeCachedHubDownloader: Downloader {{
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {{
        {download_guard}
        let commit = HubCache.default.resolveRevision(
            repo: repo,
            kind: .model,
            ref: {download_ref}
        )
        return snapshot
    }}
}}

public actor NovaForgeMLXRuntime {{
    private static func cachedSnapshotURL(profile: NovaForgeMLXProfile) -> URL? {{
        guard let commit = HubCache.default.resolveRevision(
            repo: repo,
            kind: .model,
            ref: {cached_ref}
        ) else {{
            return nil
        }}
        return snapshot
    }}
}}
"""


def run_self_test() -> list[str]:
    valid = _fixture_source(
        download_guard=(
            'guard let requestedRevision = revision else { '
            'throw RuntimeError.missingRevision }'
        ),
        download_ref="requestedRevision",
        cached_ref="profile.revision",
    )
    shorthand = _fixture_source(
        download_guard=(
            'guard let revision else { throw RuntimeError.missingRevision }'
        ),
        download_ref="revision",
        cached_ref="profile.revision",
    )
    optional_fallback = _fixture_source(
        download_guard='let requestedRevision = revision ?? "main"',
        download_ref="requestedRevision",
        cached_ref="profile.revision",
    )
    wrong_downloader_ref = _fixture_source(
        download_guard=(
            'guard let requestedRevision = revision else { '
            'throw RuntimeError.missingRevision }'
        ),
        download_ref="id",
        cached_ref="profile.revision",
    )
    wrong_cached_ref = _fixture_source(
        download_guard=(
            'guard let requestedRevision = revision else { '
            'throw RuntimeError.missingRevision }'
        ),
        download_ref="requestedRevision",
        cached_ref="profile.repositoryID",
    )

    validate_runtime_source(valid, source_name="self-test-valid")
    validate_runtime_source(shorthand, source_name="self-test-shorthand")

    for name, source in (
        ("optional revision fallback", optional_fallback),
        ("different downloader ref", wrong_downloader_ref),
        ("different cached-snapshot ref", wrong_cached_ref),
    ):
        try:
            validate_runtime_source(source, source_name=f"self-test-{name}")
        except ValidationError:
            pass
        else:
            raise ValidationError(f"self-test expected rejection for {name}")

    with tempfile.TemporaryDirectory() as temporary:
        result = validate_repo(Path(temporary))
        if "not present" not in result[0]:
            raise ValidationError(
                "self-test expected absent MLX runtime to pass without qualification"
            )

    return [
        "explicit fail-closed revision binding accepted",
        "Swift shorthand fail-closed revision binding accepted",
        "optional revision fallback rejected",
        "downloader cache-ref drift rejected",
        "cached-snapshot profile-ref drift rejected",
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
