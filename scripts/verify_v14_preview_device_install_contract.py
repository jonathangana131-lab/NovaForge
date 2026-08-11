#!/usr/bin/env python3
"""Static fail-closed contract for the local connected-iPhone Preview installer."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INSTALLER = Path("scripts/codex-device-preview-install.sh")


class ContractError(RuntimeError):
    pass


def require(source: str, needle: str, message: str) -> None:
    if needle not in source:
        raise ContractError(message)


def reject(source: str, needle: str, message: str) -> None:
    if needle in source:
        raise ContractError(message)


def validate_source(source: str) -> list[str]:
    required = [
        ('EXPECTED_PRODUCT_TYPE="${EXPECTED_PRODUCT_TYPE:-iPhone13,2}"', "iPhone 12 product-type baseline disappeared"),
        ('EXPECTED_IOS_MAJOR="${EXPECTED_IOS_MAJOR:-27}"', "iOS 27 baseline disappeared"),
        ('SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD', "exact Git source binding disappeared"),
        ('status --porcelain --untracked-files=all', "clean-worktree gate disappeared"),
        ('Refusing device build from a dirty worktree.', "dirty-source failure is no longer explicit"),
        ('xcrun devicectl device info details', "connected-device identity inspection disappeared"),
        ('--json-output "$DEVICE_JSON"', "machine-readable device identity receipt disappeared"),
        ('python3 - "$DEVICE_JSON" "$EXPECTED_PRODUCT_TYPE" "$EXPECTED_IOS_MAJOR"', "device product/OS validation disappeared"),
        ('-destination "platform=iOS,id=$DEVICE_ID"', "xcodebuild is no longer bound to the selected physical device"),
        ('-allowProvisioningUpdates', "automatic-signing provisioning support disappeared"),
        ('"NOVAFORGE_SOURCE_COMMIT=$SOURCE_SHA"', "embedded source marker build setting disappeared"),
        ("Print :NovaForgeSourceCommit", "built-app source marker verification disappeared"),
        ('if [[ "$EMBEDDED_SHA" != "$SOURCE_SHA" ]]', "built-app source mismatch no longer fails closed"),
        ('codesign -dv --verbose=4 "$APP_PATH"', "device build no longer verifies code signing"),
        ('xcrun devicectl device install app', "connected-device installation command disappeared"),
        ('--device "$DEVICE_ID"', "device install/inspection is no longer explicitly device-bound"),
        ('deviceIdentifierSHA256=$DEVICE_ID_SHA256', "receipt no longer pseudonymizes the selected device identifier"),
        ('$HOME/Library/Logs/NovaForge/PreviewInstall/', "default receipt location moved into or away from the local Mac log boundary"),
        ('It does not prove Local AI quality, provider health, performance, thermals, accessibility, visual acceptance, or successful app journeys.', "receipt truth boundary disappeared"),
    ]
    for needle, message in required:
        require(source, needle, message)

    forbidden = [
        ('CODE_SIGNING_ALLOWED=NO', "physical Preview installer must not disable signing"),
        ('ALLOW_DIRTY', "exact-source device evidence must not expose a dirty-worktree bypass"),
        ('if ! run_with_timeout', "negated timeout helper loses the original failure status; use command || { status=$?; ... }"),
        ('DEVICE_ID="4B9AB34A-', "Simulator UUID must not be hard-coded into the physical-device installer"),
    ]
    for needle, message in forbidden:
        reject(source, needle, message)

    # Reject accidental checked-in Apple Team IDs or physical-device identifiers.
    if re.search(r'DEVELOPMENT_TEAM="[A-Z0-9]{10}"', source):
        raise ContractError("do not commit an Apple Development Team identifier")
    if re.search(r'DEVICE_ID="[0-9A-Fa-f-]{20,}"', source):
        raise ContractError("do not commit a physical device identifier")

    # Each fallible long-running device/build/install operation must preserve the
    # actual command status via `|| { status=$?; ... }`; a shell `if ! command`
    # construct would make `$?` report the negation instead.
    required_fail_closed_commands = [
        'run_with_timeout "$DEVICE_TIMEOUT" xcrun devicectl device info details',
        'run_with_timeout "$BUILD_TIMEOUT" xcodebuild "${BUILD_ARGS[@]}" build',
        'run_with_timeout "$DEVICE_TIMEOUT" xcrun devicectl device install app',
    ]
    for command in required_fail_closed_commands:
        index = source.find(command)
        if index < 0:
            raise ContractError(f"missing fail-closed command: {command}")
        trailer = source[index : index + 500]
        if '|| {' not in trailer or 'status=$?' not in trailer or 'exit "$status"' not in trailer:
            raise ContractError(f"command no longer preserves non-zero failure status: {command}")

    return [
        "defaults to iPhone 12 / iOS 27 identity checks",
        "requires exact clean Git source and verifies embedded source marker",
        "keeps signing enabled and binds xcodebuild/install to selected device",
        "preserves command failure statuses instead of failing open",
        "keeps device/signing identities out of repository defaults",
        "receipt carries explicit non-acceptance boundaries",
    ]


def run_self_test(source: str) -> list[str]:
    validate_source(source)

    mutations = [
        ("dirty bypass", source.replace("WORKTREE_STATUS=", "ALLOW_DIRTY=1\nWORKTREE_STATUS=", 1)),
        ("unsigned device build", source.replace("CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=NO", 1)),
        ("lost source marker", source.replace("Print :NovaForgeSourceCommit", "Print :CFBundleVersion", 1)),
        ("negated timeout", source.replace(
            'run_with_timeout "$BUILD_TIMEOUT" xcodebuild',
            'if ! run_with_timeout "$BUILD_TIMEOUT" xcodebuild',
            1,
        )),
    ]
    for name, mutated in mutations:
        try:
            validate_source(mutated)
        except ContractError:
            pass
        else:
            raise ContractError(f"self-test expected rejection: {name}")

    return [
        "dirty-source bypass rejected",
        "unsigned device build rejected",
        "lost embedded-source verification rejected",
        "negated timeout/failure-status regression rejected",
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    path = args.repo_root.resolve() / INSTALLER
    try:
        source = path.read_text(encoding="utf-8")
        if args.self_test:
            for message in run_self_test(source):
                print(f"[PASS] self-test: {message}")
        for message in validate_source(source):
            print(f"[PASS] {message}")
    except (OSError, UnicodeError, ContractError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
