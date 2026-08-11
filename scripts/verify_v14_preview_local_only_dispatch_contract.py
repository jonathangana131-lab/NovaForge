#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def fail(message: str) -> None:
    raise SystemExit(f"Preview Local Only dispatch contract: FAIL: {message}")


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing {relative}")
    return path.read_text(encoding="utf-8")


def require(text: str, needles: list[str], label: str) -> None:
    for needle in needles:
        if needle not in text:
            fail(f"{label} missing: {needle}")


def forbid(text: str, needles: list[str], label: str) -> None:
    for needle in needles:
        if needle in text:
            fail(f"{label} contains forbidden marker: {needle}")


def case_blocks(source: str, case_name: str) -> list[str]:
    lines = source.splitlines()
    blocks: list[str] = []
    pattern = re.compile(rf"^(\s*)case\s+\.{re.escape(case_name)}\s*:\s*$")
    for start, line in enumerate(lines):
        match = pattern.match(line)
        if not match:
            continue
        indent = len(match.group(1))
        peer = re.compile(rf"^\s{{{indent}}}(?:case\b|default\s*:)")
        end = next((i for i in range(start + 1, len(lines)) if peer.match(lines[i])), len(lines))
        blocks.append("\n".join(lines[start:end]))
    return blocks


composition = read("AgentPad/Services/AgentSystemProductionComposition.swift")
gateway = read("AgentPad/Services/AgentProductionProviderGateway.swift")
router = read("AgentPad/Services/AgentProviderTransportRouter.swift")
local_transport = read("AgentPad/Services/AgentLocalModelProviderTransport.swift")

local_cases = case_blocks(composition, "builtInLocalModel")
credential_cases = [b for b in local_cases if "credential = nil" in b and "hostedAccountID = nil" in b]
if len(credential_cases) != 1:
    fail(f"expected exactly one credential-free local environment case, found {len(credential_cases)}")
forbid(credential_cases[0], ["KeychainStore", "credential = try", "prepareCredential"], "local environment case")

gateway_cases = [b for b in local_cases if ".localSingleCallTools(modelID: route.modelID)" in b]
if len(gateway_cases) != 1:
    fail(f"expected exactly one local gateway case, found {len(gateway_cases)}")
require(gateway_cases[0], [
    "selection.declaredDescriptor.route == route",
    "AgentProductionProviderGatewayFactory",
    ".localSingleCallTools(",
], "local gateway case")
forbid(gateway_cases[0], [".hostedOpenAI", ".hostedOpenCodeZen", "credential:", "chatGPTAccountID"], "local gateway case")

factory_start = gateway.find("static func localSingleCallTools(\n        selection: AgentProductionProviderRouteSelection,\n        workspace: SandboxWorkspace\n    ) throws -> AgentProductionProviderGatewayBundle {")
factory_end = gateway.find("static func localSingleCallTools(\n        selection: AgentProductionProviderRouteSelection,\n        workspace: SandboxWorkspace,", factory_start + 1)
if factory_start < 0 or factory_end < 0:
    fail("cannot isolate production localSingleCallTools factory")
factory = gateway[factory_start:factory_end]
require(factory, [
    "LocalToolsAuthority(modelID: selection.modelID)",
    "transport: AgentLocalModelProviderTransport(",
    "inference: LocalModelClient.shared",
    "singleCallToolsCapability: authority.capability",
], "local gateway factory")
forbid(factory, ["AgentHostedProviderTransport", "HostedAuthority", "credential:", "chatGPTAccountID"], "local gateway factory")

private_start = gateway.find("private static func localSingleCallTools(")
private_end = gateway.find("static func hostedOpenAICodexResponses(", private_start + 1)
if private_start < 0 or private_end < 0:
    fail("cannot isolate sealed local router factory")
private_factory = gateway[private_start:private_end]
require(private_factory, [
    "guard selection.lane == .localSingleCallTools else",
    "guard selection.declaredDescriptor == authority.descriptor else",
    ".init(descriptor: authority.descriptor, transport: transport)",
    "catalog: authority.catalog",
    "transport: router",
], "sealed local router factory")
forbid(private_factory, ["AgentHostedProviderTransport", "credential:", "bindings.append", ".hosted"], "sealed local router factory")

require(router, [
    "let adapterID = descriptor.route.adapterID",
    "guard let binding = bindings[adapterID] else",
    "guard binding.descriptor == descriptor else",
    "return try await binding.transport.stream(",
], "provider transport router")
forbid(router, ["bindings.first", "bindings.values.first", "??"], "provider transport router")

require(local_transport, [
    "protocol AgentLocalModelInferenceStreaming: Sendable",
    "private let inference: any AgentLocalModelInferenceStreaming",
    "inference: LocalModelClient.shared",
], "local provider transport")
forbid(local_transport, [
    "AgentHostedProviderTransport", "URLSession", "URLRequest",
    "URLSessionConfiguration", "OpenAIClient", "api.openai.com", "opencode.ai",
], "local provider transport")

print("Preview Local Only dispatch contract: PASS")
print("- local environment resolves hosted credential/account ID to nil")
print("- local route selects the localSingleCallTools gateway")
print("- production local gateway constructs AgentLocalModelProviderTransport with LocalModelClient.shared")
print("- sealed local router binds only the local authority/transport seam")
print("- transport router requires exact adapter ID + descriptor before dispatch")
print("- local provider transport has no hosted transport or URLSession/URLRequest primitive")
print("- source evidence only; dynamic network and exact-device proof remain separate")
