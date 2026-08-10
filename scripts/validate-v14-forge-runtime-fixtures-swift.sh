#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME="$ROOT/Packages/ForgeRuntimeKit/Sources/ForgeRuntime"
FIXTURES="$ROOT/Fixtures/ForgeRuntime/V14"
SWIFTC=${SWIFTC:-swiftc}

for source in ForgeRuntimeManifest.swift ForgeRuntimeManifestValidator.swift ForgeRuntimeLaunchAuthorization.swift; do
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
let fixtures = ["focus-notes", "vector-drift"]
var failed = false

for name in fixtures {
    let manifestURL = fixtureRoot
        .appendingPathComponent(name, isDirectory: true)
        .appendingPathComponent("novaforge.runtime.json", isDirectory: false)

    do {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try ForgeRuntimeManifestDecoder().decode(data)
        let report = ForgeRuntimeManifestValidator().validate(
            manifest,
            expectedProjectID: manifest.projectID,
            host: .init()
        )

        if report.isLaunchable {
            print("PASS \(name): RuntimeKit decoder + validator accepted (warnings=\(report.warnings.count))")
        } else {
            failed = true
            let errors = report.errors
                .map { "\($0.code.rawValue):\($0.field)" }
                .joined(separator: ", ")
            print("FAIL \(name): \(errors)")
        }
    } catch {
        failed = true
        print("FAIL \(name): \(error)")
    }
}

if failed {
    exit(1)
}

print("Truth boundary: RuntimeKit manifest acceptance is not launch, self-play, visual, device, performance, or completion evidence.")
SWIFT

"$SWIFTC" -warnings-as-errors -o "$WORK/validate-fixtures" \
  "$RUNTIME/ForgeRuntimeManifest.swift" \
  "$RUNTIME/ForgeRuntimeManifestValidator.swift" \
  "$RUNTIME/ForgeRuntimeLaunchAuthorization.swift" \
  "$WORK/main.swift"

"$WORK/validate-fixtures" "$FIXTURES"
