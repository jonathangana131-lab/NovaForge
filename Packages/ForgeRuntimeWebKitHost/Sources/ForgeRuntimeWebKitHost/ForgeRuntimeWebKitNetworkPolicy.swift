import Foundation
import ForgeRuntime
import WebKit

public enum ForgeRuntimeWebKitNetworkPolicyError: Error, Equatable, Sendable {
    case ruleEncodingFailed
    case ruleStoreUnavailable
    case ruleCompilationFailed
}

/// Package-issued proof that WebKit content filtering was compiled from an exact validated Forge
/// network authority. The compiled rule list is intentionally package-owned so ordinary consumers
/// cannot substitute an arbitrary allow-all list while claiming a stricter authorization.
public struct ForgeRuntimeWebKitNetworkPolicyReceipt: Sendable {
    public let policy: ForgeAuthorizedNetworkPolicy
    let ruleList: WKContentRuleList

    init(policy: ForgeAuthorizedNetworkPolicy, ruleList: WKContentRuleList) {
        self.policy = policy
        self.ruleList = ruleList
    }
}

/// Compiles the exact host-derived Forge network authority into a WebKit content rule list before a
/// generated artifact is executed.
///
/// Forge Runtime grants only HTTPS exact-host authority. The generated rule list therefore blocks
/// ordinary HTTP/HTTPS/WebSocket network schemes by default and reopens only canonical allowlisted
/// HTTPS hosts on the default HTTPS port. Omitting `resource-type` is intentional: WebKit applies
/// the rules to every supported resource type, including documents, scripts, images, fetches and
/// WebSockets.
@MainActor
public struct ForgeRuntimeWebKitNetworkPolicyCompiler {
    public init() {}

    public func compile(
        _ policy: ForgeAuthorizedNetworkPolicy
    ) async throws -> ForgeRuntimeWebKitNetworkPolicyReceipt {
        guard let store = WKContentRuleListStore.default() else {
            throw ForgeRuntimeWebKitNetworkPolicyError.ruleStoreUnavailable
        }

        let source: String
        do {
            source = try ForgeRuntimeWebKitNetworkRuleSource.encoded(for: policy)
        } catch {
            throw ForgeRuntimeWebKitNetworkPolicyError.ruleEncodingFailed
        }

        let identifier = "NovaForge.ForgeRuntime.Network.\(UUID().uuidString)"
        let ruleList: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    _ = error
                    continuation.resume(
                        throwing: ForgeRuntimeWebKitNetworkPolicyError.ruleCompilationFailed
                    )
                }
            }
        }

        return ForgeRuntimeWebKitNetworkPolicyReceipt(policy: policy, ruleList: ruleList)
    }
}

enum ForgeRuntimeWebKitNetworkRuleSource {
    private static let blockedSchemes = ["http", "https", "ws", "wss"]

    static func encoded(for policy: ForgeAuthorizedNetworkPolicy) throws -> String {
        var rules: [[String: Any]] = blockedSchemes.map { scheme in
            [
                "trigger": ["url-filter": "^\(scheme)://"],
                "action": ["type": "block"],
            ]
        }

        if policy.mode == .allowListedHTTPS {
            for host in policy.allowedHosts {
                rules.append([
                    "trigger": [
                        // Match the resource URL itself. Do not add `if-domain`: WebKit domain
                        // conditions are document-context filters, while Forge launches a local
                        // `file://` document that must still be able to reach its exact allowlist.
                        "url-filter": "^https://\(escapedExactHost(host))(:443)?/",
                    ],
                    "action": ["type": "ignore-previous-rules"],
                ])
            }
        }

        guard JSONSerialization.isValidJSONObject(rules) else {
            throw ForgeRuntimeWebKitNetworkPolicyError.ruleEncodingFailed
        }
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        guard let source = String(data: data, encoding: .utf8) else {
            throw ForgeRuntimeWebKitNetworkPolicyError.ruleEncodingFailed
        }
        return source
    }

    private static func escapedExactHost(_ host: String) -> String {
        host.replacingOccurrences(of: ".", with: "\\.")
    }
}
