# V14 Preview Connected-Device Install Tooling

Protocol: `NF-SWARM-v14`  
Worker: `GPT56-SOL-NF-V14-PREVIEW-DEVICE-INSTALL-0810`  
Base: `main@991ece0ed9add9acf1108055f489b25f6cc9843f`  
Branch: `agent/v14-preview-device-install`

## Why this lane exists

The Preview directive is explicitly aiming for a polished build the user can try before the full NovaForge 2.0 shell rewrite. The repository has strong Simulator build/test tooling, but the live ownership scan found no dedicated repo-owned command for the last local Mac handoff:

`clean exact source -> signed device build -> exact connected iPhone -> install -> local receipt`

This lane adds that handoff without changing the app, signing configuration, provider/runtime behavior, Local AI, themes, sessions, or Xcode project.

## Command

From a clean NovaForge checkout on the Mac with Xcode selected and the iPhone connected/trusted:

```bash
xcrun devicectl list devices
DEVICE_ID='<connected device identifier>' bash scripts/codex-device-preview-install.sh
```

The user can optionally provide `DEVELOPMENT_TEAM` if the Xcode project/account does not already resolve the signing team. Automatic provisioning updates are enabled for the build; automatic device registration is opt-in with `ALLOW_PROVISIONING_DEVICE_REGISTRATION=1` rather than silently mutating the developer account.

## Default qualification identity

The command fails closed unless the connected device details contain:

- product type `iPhone13,2` — iPhone 12;
- an iOS `27.x` version.

`EXPECTED_PRODUCT_TYPE` and `EXPECTED_IOS_MAJOR` can be intentionally overridden for a non-baseline install, and the receipt records those configured expectations. A non-baseline install must never be promoted into iPhone 12 qualification evidence.

## Exact-source binding

The installer refuses a dirty worktree, including untracked files, before building. That prevents local edits from being stamped with an unrelated Git commit.

The device build passes the exact `HEAD` SHA through `NOVAFORGE_SOURCE_COMMIT`, then reads `NovaForgeSourceCommit` back from the built app's `Info.plist`. Installation is refused unless the embedded marker exactly equals the clean checkout SHA.

## Signing and installation

The script:

1. inspects the explicitly selected connected device through Xcode `devicectl` and writes the machine-readable details only to a local Mac log directory;
2. builds `NovaForge.app` for `platform=iOS,id=<selected device>` with normal automatic signing enabled;
3. verifies the built app is code signed and has the expected NovaForge bundle identifier;
4. installs the exact built app with `xcrun devicectl device install app`;
5. optionally launches it with `LAUNCH_AFTER_INSTALL=1`;
6. writes a local receipt under `~/Library/Logs/NovaForge/PreviewInstall/...`.

No device identifier, Apple Team ID, signing certificate, provisioning profile, account credential, or provider secret is committed to the repository. The receipt stores only a SHA-256 digest of the selected device identifier in its summary; the raw `devicectl` identity JSON remains local next to the build/install logs.

## Fail-closed regression

`scripts/verify_v14_preview_device_install_contract.py` plus `.github/workflows/v14-preview-device-install-contract.yml` lock the tooling boundary without pretending Ubuntu CI can perform a physical iPhone install.

The static contract requires:

- iPhone 12 / iOS 27 defaults;
- exact Git SHA plus clean-worktree enforcement;
- machine-readable connected-device identity validation;
- physical-device `xcodebuild` destination binding;
- signing enabled;
- embedded source-marker verification;
- `devicectl` installation on the selected device;
- local/pseudonymized receipt handling;
- preservation of real nonzero exit statuses from timed device/build/install commands.

The adversarial self-test rejects a dirty-source bypass, unsigned build, removed embedded-source verification, and the shell-negation error pattern that can otherwise turn a failed command into a zero exit status.

## Validation truth

This worker does not have Xcode or the user's connected iPhone in its execution environment, so **no physical-device build/install success is claimed by this branch**. The permanent CI lane validates only shell syntax and the fail-closed source contract. The real install receipt must be generated later on the user's Mac/device from the exact release candidate.

## Acceptance boundary

A successful installer receipt proves only that one clean NovaForge commit was built, signed, and installed on a connected device matching the configured identity checks. It does **not** prove:

- Local AI inference quality, memory use, thermals, energy, or speed;
- provider authentication/health or a real hosted response;
- Local Only zero-egress behavior;
- accessibility or visual acceptance;
- long-session performance;
- successful agent/tool journeys;
- Preview release readiness by itself.

Those remain separate V14 evidence classes and must be combined only on the exact accepted release candidate.
