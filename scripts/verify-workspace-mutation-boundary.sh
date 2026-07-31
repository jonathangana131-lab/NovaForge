#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

GATEWAY="AgentPad/Services/WorkspaceMutationGateway.swift"
WORKSPACE="AgentPad/Tools/SandboxWorkspace.swift"
EXECUTOR="AgentPad/Tools/SandboxToolExecutor.swift"
COMMAND_RUNNER="AgentPad/Tools/CommandRunner.swift"
JOURNAL="AgentPad/Services/WorkspaceMutationJournal.swift"
ENGINE_PREPARATION="AgentPad/Services/AgentPolicyEngineMutationAdapter.swift"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for required_file in "$GATEWAY" "$JOURNAL" "$WORKSPACE" "$EXECUTOR" "$COMMAND_RUNNER"; do
  [ -f "$required_file" ] || fail "missing mutation-boundary source: $required_file"
done

if [ -f "$ENGINE_PREPARATION" ]; then
  rg -q 'system\.storePaths\.versionDirectory\.appendingPathComponent' \
    "$ENGINE_PREPARATION" || \
    fail "engine preparation ledger must stay rooted in fixed AgentPolicy store paths"
fi

# These checks are a source-level regression net. They complement compilation
# and runtime tests; they do not claim to prove security for arbitrary Swift.
rg -q 'struct WorkspaceMutationPermit: Sendable' "$GATEWAY" || \
  fail "WorkspaceMutationPermit is missing"
rg -q 'fileprivate init\(request: WorkspaceMutationRequest\)' "$GATEWAY" || \
  fail "WorkspaceMutationPermit must keep its request-bound file-private initializer"
rg -q 'private final class WorkspaceMutationCapabilityState' "$GATEWAY" || \
  fail "WorkspaceMutationPermit must retain private sealed state"
rg -q 'case revoked\(operationID: UUID\)' "$GATEWAY" || \
  fail "WorkspaceMutationPermit must support revocation"
rg -q 'defer \{ permit\.revoke\(\) \}' "$GATEWAY" || \
  fail "gateway effect dispatch must revoke escaped permit copies"

permit_constructors=$(rg -n 'WorkspaceMutationPermit\(request:' AgentPad --glob '*.swift' || true)
if [ "$(printf '%s\n' "$permit_constructors" | sed '/^$/d' | wc -l | tr -d ' ')" -ne 1 ] || \
   ! grep -q '^AgentPad/Services/WorkspaceMutationGateway.swift:' <<< "$permit_constructors"; then
  echo "$permit_constructors" >&2
  fail "only WorkspaceMutationGateway may construct a mutation permit"
fi

rg -q 'fileprivate init\(' "$GATEWAY" || \
  fail "production gateway dependency injection must stay file-private"
rg -q '#if AGENTPAD_TESTING' "$GATEWAY" || \
  fail "injected gateway construction must stay behind the test-only condition"

rg -q 'func snapshot\(operationID: UUID\)' "$JOURNAL" || \
  fail "journal must expose durable phase snapshots for replay decisions"
rg -q 'case \.completed:' "$GATEWAY" || \
  fail "gateway replay policy must recognize completed receipts"
rg -q 'case \.applied:' "$GATEWAY" || \
  fail "gateway replay policy must settle applied receipts without re-effect"
rg -q 'case \.executing, \.interrupted, \.failed:' "$GATEWAY" || \
  fail "gateway replay policy must stop ambiguous receipts"

perl -0777 -e '
  my $source = <>;
  exit(($source =~ /func\s+perform\s*\([^)]*effect:\s*\@Sendable\s*\(WorkspaceMutationPermit\)/s) ? 0 : 1);
' "$GATEWAY" || fail "gateway.perform must supply a nonoptional permit"

for method in write createNewFile append touch makeDirectory createNewDirectory delete move copy reset; do
  METHOD="$method" perl -0777 -e '
    my $method = $ENV{METHOD};
    my $source = <>;
    exit(($source =~ /func\s+\Q$method\E\s*\([^)]*permit:\s*WorkspaceMutationPermit/s) ? 0 : 1);
  ' "$WORKSPACE" || fail "SandboxWorkspace.$method must require WorkspaceMutationPermit"
done

workspace_validation_count=$(rg -c 'permit\.validate\(workspace: self' "$WORKSPACE" || true)
if [ "${workspace_validation_count:-0}" -lt 10 ]; then
  fail "workspace raw mutation methods must validate request-bound capabilities"
fi

perl -0777 -e '
  my $source = <>;
  exit(($source =~ /func\s+execute\s*\([^)]*permit:\s*WorkspaceMutationPermit/s) ? 0 : 1);
' "$EXECUTOR" || fail "SandboxToolExecutor needs a permit-bearing execute overload"
rg -q 'operation: \.replaceText\(path: path\)' "$EXECUTOR" || \
  fail "replace_text must validate its mutation capability before raw writes"

perl -0777 -e '
  my $source = <>;
  exit(($source =~ /func\s+run\s*\([^)]*permit:\s*WorkspaceMutationPermit/s) ? 0 : 1);
' "$COMMAND_RUNNER" || fail "CommandRunner needs a permit-bearing run overload"
rg -q 'validateTerminalMutation\(commandLine, permit: permit\)' "$COMMAND_RUNNER" || \
  fail "mutating terminal commands must validate the exact command and paths"

# Two non-workspace persistence seams intentionally use Foundation directly:
# the simulator-only approval key substitute and the opt-in physical-device
# local-model smoke receipt. Pin both to their exact source/target identities
# before the raw-writer allowlist below can classify their individual calls.
rg -q '#if targetEnvironment\(simulator\)' \
  AgentPad/Infrastructure/Policy/AgentApprovalSigningKeyStore.swift || \
  fail "simulator approval-key file client must stay simulator-only"
rg -q '"LocalAgentSmokeProof\.json"' AgentPad/Views/AppRootView.swift || \
  fail "local smoke receipt must stay pinned to its fixed Application Support file"

constructor_region=$(sed -n '/struct SandboxWorkspace: Sendable {/,/private var standardizedRootPath:/p' "$WORKSPACE")
if rg -n 'createDirectory|removeItem|moveItem|copyItem|\.write\(' <<< "$constructor_region"; then
  fail "SandboxWorkspace initialization must be side-effect free"
fi

# Inspect balanced Swift call argument lists for every workspace-like receiver.
# This complements the compiler: it fails immediately with a precise call site
# if a future caller omits the capability label.
call_violations=""
while IFS= read -r swift_file; do
  file_violations=$(perl -0777 -e '
    my $source = <>;
    while ($source =~ /\b(?<receiver>(?:[A-Za-z_]\w*\.)*[A-Za-z_0-9]*[Ww]orkspace)\s*\.\s*(?<method>write|createNewFile|append|touch|makeDirectory|createNewDirectory|delete|move|copy|reset)\s*(?<args>\((?:[^()]++|(?&args))*\))/g) {
      next if $+{args} =~ /\bpermit\s*:/;
      my $line = 1 + (substr($source, 0, $-[0]) =~ tr/\n//);
      print "$ARGV:$line:$+{receiver}.$+{method} omits permit:\n";
    }
  ' "$swift_file")
  if [ -n "$file_violations" ]; then
    call_violations+="$file_violations"$'\n'
  fi
done < <(rg --files AgentPad --glob '*.swift')

if [ -n "$call_violations" ]; then
  printf '%s' "$call_violations" >&2
  fail "workspace primitive calls must carry the gateway-issued permit"
fi

# Classify known raw-writer call sites so a new match receives human review.
# This is intentionally an allowlist audit, not a proof that every possible
# Foundation or POSIX write spelling has been enumerated.
raw_writer_pattern='FileManager\.default\.(createDirectory|removeItem|moveItem|copyItem|replaceItemAt|setAttributes)|\.write\(to:|write\(toFile:|createFile\(atPath:|FileHandle\(forWriting'
raw_violations=""
while IFS= read -r match; do
  [ -n "$match" ] || continue
  path=${match%%:*}
  remainder=${match#*:}
  line=${remainder%%:*}
  source=${remainder#*:}

  case "$path" in
    AgentPad/Tools/SandboxWorkspace.swift|\
    AgentPad/Tools/SandboxToolExecutor.swift|\
    AgentPad/Services/LocalModelRuntime.swift|\
    AgentPad/App/AgentPadApp.swift)
      ;;
    AgentPad/Services/AgentPolicyEngineMutationAdapter.swift)
      # This is the fixed Application Support policy-preparation ledger, not a
      # workspace effect. Permit only its exact atomic ledger replacement;
      # every other raw writer spelling in the adapter still fails review.
      if [[ "$source" != *'write(to: fileURL, options: [.atomic])'* ]]; then
        raw_violations+="$match"$'\n'
      fi
      ;;
    AgentPad/Infrastructure/Persistence/AgentRecoveryLeadershipLease.swift)
      # The recovery-leader lease is fixed harness metadata under Application
      # Support, never a project/workspace target. Its sole Foundation writer
      # applies complete file protection after the POSIX descriptor and path
      # identities have both been pinned and validated.
      if [[ "$source" != *'FileManager.default.setAttributes('* ]]; then
        raw_violations+="$match"$'\n'
      fi
      ;;
    AgentPad/Infrastructure/Policy/AgentApprovalSigningKeyStore.swift)
      # Simulator XCTest cannot rely on the host Keychain. This client writes
      # one protected fixed Application Support key file and is compiled only
      # for targetEnvironment(simulator); it never accepts a workspace path.
      if [[ "$source" != *'try data.write(to: fileURL, options: [.withoutOverwriting])'* ]]; then
        raw_violations+="$match"$'\n'
      fi
      ;;
    AgentPad/Views/AppRootView.swift)
      # The --local-smoke-test device-only proof is copied out by the signed
      # install verifier. Its directory and proofURL are fixed Application
      # Support identities; no provider/workspace path reaches this writer.
      if [[ "$source" != *'try FileManager.default.createDirectory('* && \
            "$source" != *'try data.write(to: proofURL, options: .atomic)'* ]]; then
        raw_violations+="$match"$'\n'
      fi
      ;;
    AgentPad/Views/FilesView+Search.swift)
      if [[ "$source" != *destinationURL* && "$source" != *zipURL* ]]; then
        raw_violations+="$match"$'\n'
      fi
      ;;
    *)
      raw_violations+="$match"$'\n'
      ;;
  esac
done < <(rg -n "$raw_writer_pattern" AgentPad --glob '*.swift' || true)

if [ -n "$raw_violations" ]; then
  printf '%s' "$raw_violations" >&2
  fail "unclassified raw filesystem writer found outside the mutation boundary"
fi

echo "PASS: static mutation-boundary capability and replay checks passed."
