#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME="$ROOT/Packages/ForgeRuntimeKit/Sources/ForgeRuntime"
FIXTURES="$ROOT/Fixtures/ForgeRuntime/V14"
SWIFTC=${SWIFTC:-swiftc}

for source in ForgeRuntimeManifest.swift ForgeRuntimeManifestValidator.swift ForgeRuntimeLaunchAuthorization.swift ForgeRuntimeProjectLoader.swift; do
  if [ ! -f "$RUNTIME/$source" ]; then
    echo "FAIL: missing RuntimeKit source: $RUNTIME/$source" >&2
    exit 1
  fi
done

TMPDIR_ROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$TMPDIR_ROOT/novaforge-v14-fixtures-swift.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fixtures = [
    (directory: "focus-notes", projectID: "fixture.focus-notes"),
    (directory: "vector-drift", projectID: "fixture.vector-drift"),
]
var failed = false

for fixture in fixtures {
    let projectRoot = fixtureRoot.appendingPathComponent(fixture.directory, isDirectory: true)
    do {
        let request = try ForgeRuntimeProjectLoader().load(
            projectRootURL: projectRoot,
            expectedProjectID: fixture.projectID,
            host: .init()
        )
        let authorization = request.authorization
        guard authorization.projectID == fixture.projectID,
              authorization.entryPoint == "index.html",
              request.entryPointURL.lastPathComponent == "index.html",
              request.assetURLs.isEmpty,
              authorization.grantedCapabilityIDs.isEmpty,
              authorization.network.mode == .denied,
              authorization.network.allowedHosts.isEmpty,
              authorization.modules.isEmpty else {
            failed = true
            print("FAIL \(fixture.directory): derived pre-launch authority widened or resolved unexpected files")
            continue
        }
        print("PASS \(fixture.directory): RuntimeKit project loader accepted + sandbox-resolved entry point")
    } catch {
        failed = true
        print("FAIL \(fixture.directory): \(error)")
    }
}

if failed {
    exit(1)
}

print("Truth boundary: RuntimeKit pre-launch loading is not WebKit launch, self-play, visual, device, performance, or completion evidence.")
SWIFT

"$SWIFTC" -warnings-as-errors -o "$WORK/validate-fixtures" \
  "$RUNTIME/ForgeRuntimeManifest.swift" \
  "$RUNTIME/ForgeRuntimeManifestValidator.swift" \
  "$RUNTIME/ForgeRuntimeLaunchAuthorization.swift" \
  "$RUNTIME/ForgeRuntimeProjectLoader.swift" \
  "$WORK/main.swift"

"$WORK/validate-fixtures" "$FIXTURES"
