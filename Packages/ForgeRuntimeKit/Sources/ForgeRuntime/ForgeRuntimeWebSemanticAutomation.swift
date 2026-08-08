import Foundation

/// Stable DOM/event names used by Forge Runtime web projects that opt into semantic automation.
///
/// Generated projects may expose these semantic endpoints, but they never grant automation
/// authority. Native host policy must authorize an interaction before this adapter can serialize it.
public enum ForgeRuntimeWebSemanticContract {
    public static let controlAttribute = "data-novaforge-control"
    public static let textInputAttribute = "data-novaforge-text-input"
    public static let actionAttribute = "data-novaforge-action"
    public static let gestureAttribute = "data-novaforge-gesture"
    public static let actionEventName = "novaforge:action"
    public static let gestureEventName = "novaforge:gesture"
}

public enum ForgeRuntimeWebSemanticAutomationError: Error, Equatable, Sendable {
    case hostLifecycleInteractionRequired
    case commandEncodingFailed
    case bridgeUnavailable
    case invalidBridgeResult
    case resultTooLarge(actualBytes: Int, maximumBytes: Int)
    case resultIdentityMismatch
    case unsupportedDisposition(String)
}

/// Host-owned JavaScript dispatch plan for exactly one already-authorized semantic interaction.
///
/// The initializer is internal so untrusted model/project data cannot bypass
/// `ForgeRuntimeSemanticInteractionGate` by directly minting a dispatch plan.
public struct ForgeRuntimeWebSemanticDispatchPlan: Equatable, Sendable {
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let checkpointID: String
    public let sequence: Int
    public let javaScript: String

    init(request: ForgeRuntimeSemanticInteractionRequest, javaScript: String) {
        self.requestID = request.requestID
        self.sessionID = request.sessionID
        self.projectID = request.projectID
        self.checkpointID = request.checkpointID
        self.sequence = request.sequence
        self.javaScript = javaScript
    }
}

private struct ForgeRuntimeWebSemanticCommand: Encodable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let sessionID: String
    let projectID: String
    let checkpointID: String
    let sequence: Int
    let kind: String
    let targetID: String?
    let value: Double?
    let text: String?
    let gestureID: String?
    let durationMilliseconds: Int?
}

private struct ForgeRuntimeWebSemanticResult: Decodable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let sessionID: String
    let projectID: String
    let checkpointID: String
    let sequence: Int
    let kind: String
    let disposition: String
}

/// Pure-Foundation adapter between host-authorized Forge Runtime interactions and a web artifact.
///
/// Integration requirement: install `bootstrapJavaScript` at document start and evaluate dispatch
/// plans in a host-controlled isolated WebKit content world. Running this bridge in the generated
/// page's ordinary JavaScript world would let page code replace the bridge object and would weaken
/// the meaning of a host delivery receipt.
///
/// This adapter intentionally does not import WebKit. The app host owns navigation/process identity,
/// content-world configuration and `evaluateJavaScript` lifecycle; this package owns only the
/// deterministic semantic command/result contract.
public struct ForgeRuntimeWebSemanticAutomationAdapter: Sendable {
    public static let maximumBridgeResultUTF8Bytes = 8 * 1024

    public init() {}

    /// Installs the semantic DOM dispatcher. This source is constant and contains no model/project
    /// payload. Commands are supplied later as base64-encoded canonical JSON.
    public static let bootstrapJavaScript = #"""
    (() => {
      'use strict';
      const bridgeName = '__novaForgeHostSemanticAutomationV1';
      if (Object.prototype.hasOwnProperty.call(window, bridgeName)) return true;

      const decode = (encoded) => {
        const raw = atob(encoded);
        const bytes = Uint8Array.from(raw, (character) => character.charCodeAt(0));
        return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
      };

      const result = (command, disposition) => JSON.stringify({
        protocolVersion: command.protocolVersion,
        requestID: command.requestID,
        sessionID: command.sessionID,
        projectID: command.projectID,
        checkpointID: command.checkpointID,
        sequence: command.sequence,
        kind: command.kind,
        disposition
      });

      const exactTarget = (attribute, identifier) => {
        if (typeof identifier !== 'string') return null;
        const candidates = document.querySelectorAll(`[${attribute}]`);
        for (const candidate of candidates) {
          if (candidate.getAttribute(attribute) === identifier) return candidate;
        }
        return null;
      };

      const enterText = (target, text) => {
        if (typeof text !== 'string') return false;
        if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
          const prototype = target instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
          const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
          if (!descriptor || typeof descriptor.set !== 'function') return false;
          target.focus();
          descriptor.set.call(target, text);
          target.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertText',
            data: text
          }));
          target.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        }
        if (target instanceof HTMLElement && target.isContentEditable) {
          target.focus();
          target.textContent = text;
          target.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertText',
            data: text
          }));
          return true;
        }
        return false;
      };

      const dispatchEncoded = (encoded) => {
        let command;
        try {
          command = decode(encoded);
        } catch (_) {
          return '__NOVAFORGE_INVALID_SEMANTIC_COMMAND__';
        }

        try {
          switch (command.kind) {
          case 'control.activate': {
            const target = exactTarget('data-novaforge-control', command.targetID);
            if (!target) return result(command, 'targetUnavailable');
            if (typeof target.click !== 'function') return result(command, 'unsupportedByProject');
            target.click();
            return result(command, 'delivered');
          }
          case 'text.enter': {
            const target = exactTarget('data-novaforge-text-input', command.targetID);
            if (!target) return result(command, 'targetUnavailable');
            return result(command, enterText(target, command.text) ? 'delivered' : 'unsupportedByProject');
          }
          case 'action.set-value': {
            const target = exactTarget('data-novaforge-action', command.targetID);
            if (!target) return result(command, 'targetUnavailable');
            target.dispatchEvent(new CustomEvent('novaforge:action', {
              bubbles: true,
              detail: Object.freeze({
                requestID: command.requestID,
                sequence: command.sequence,
                actionID: command.targetID,
                value: command.value
              })
            }));
            return result(command, 'delivered');
          }
          case 'gesture.perform': {
            const target = exactTarget('data-novaforge-gesture', command.targetID);
            if (!target) return result(command, 'targetUnavailable');
            target.dispatchEvent(new CustomEvent('novaforge:gesture', {
              bubbles: true,
              detail: Object.freeze({
                requestID: command.requestID,
                sequence: command.sequence,
                gestureID: command.gestureID,
                durationMilliseconds: command.durationMilliseconds
              })
            }));
            return result(command, 'delivered');
          }
          default:
            return result(command, 'unsupportedByProject');
          }
        } catch (_) {
          return result(command, 'unsupportedByProject');
        }
      };

      Object.defineProperty(window, bridgeName, {
        value: Object.freeze({ dispatchEncoded }),
        configurable: false,
        enumerable: false,
        writable: false
      });
      return true;
    })();
    """#

    public func makeDispatchPlan(
        for authorized: ForgeRuntimeAuthorizedSemanticInteraction
    ) throws -> ForgeRuntimeWebSemanticDispatchPlan {
        let request = authorized.request
        guard request.interaction.kind != .restartRuntime else {
            throw ForgeRuntimeWebSemanticAutomationError.hostLifecycleInteractionRequired
        }

        let interaction = request.interaction
        let command = ForgeRuntimeWebSemanticCommand(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            sessionID: request.sessionID,
            projectID: request.projectID,
            checkpointID: request.checkpointID,
            sequence: request.sequence,
            kind: interaction.kind.rawValue,
            targetID: interaction.targetID,
            value: interaction.value,
            text: interaction.text,
            gestureID: interaction.gestureID,
            durationMilliseconds: interaction.durationMilliseconds
        )

        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoded = try encoder.encode(command)
        } catch {
            throw ForgeRuntimeWebSemanticAutomationError.commandEncodingFailed
        }

        let payload = encoded.base64EncodedString()
        let script = """
        (() => {
          'use strict';
          const bridge = window.__novaForgeHostSemanticAutomationV1;
          if (!bridge || typeof bridge.dispatchEncoded !== 'function') {
            return '__NOVAFORGE_SEMANTIC_BRIDGE_UNAVAILABLE__';
          }
          return bridge.dispatchEncoded('\(payload)');
        })();
        """
        return ForgeRuntimeWebSemanticDispatchPlan(request: request, javaScript: script)
    }

    /// Revalidates a web dispatch result against the exact already-authorized request before
    /// producing a deterministic delivery receipt. The web page cannot retarget a stale result to a
    /// different session/project/checkpoint/sequence or interaction kind.
    public func receipt(
        for authorized: ForgeRuntimeAuthorizedSemanticInteraction,
        bridgeResultJSON: String
    ) throws -> ForgeRuntimeSemanticInteractionReceipt {
        if bridgeResultJSON == "__NOVAFORGE_SEMANTIC_BRIDGE_UNAVAILABLE__" {
            throw ForgeRuntimeWebSemanticAutomationError.bridgeUnavailable
        }
        if bridgeResultJSON == "__NOVAFORGE_INVALID_SEMANTIC_COMMAND__" {
            throw ForgeRuntimeWebSemanticAutomationError.invalidBridgeResult
        }

        let resultBytes = Data(bridgeResultJSON.utf8)
        guard resultBytes.count <= Self.maximumBridgeResultUTF8Bytes else {
            throw ForgeRuntimeWebSemanticAutomationError.resultTooLarge(
                actualBytes: resultBytes.count,
                maximumBytes: Self.maximumBridgeResultUTF8Bytes
            )
        }

        let result: ForgeRuntimeWebSemanticResult
        do {
            result = try JSONDecoder().decode(ForgeRuntimeWebSemanticResult.self, from: resultBytes)
        } catch {
            throw ForgeRuntimeWebSemanticAutomationError.invalidBridgeResult
        }

        let request = authorized.request
        guard result.protocolVersion == request.protocolVersion,
              result.requestID == request.requestID,
              result.sessionID == request.sessionID,
              result.projectID == request.projectID,
              result.checkpointID == request.checkpointID,
              result.sequence == request.sequence,
              result.kind == request.interaction.kind.rawValue else {
            throw ForgeRuntimeWebSemanticAutomationError.resultIdentityMismatch
        }

        let disposition: ForgeRuntimeSemanticInteractionDisposition
        switch result.disposition {
        case ForgeRuntimeSemanticInteractionDisposition.delivered.rawValue:
            disposition = .delivered
        case ForgeRuntimeSemanticInteractionDisposition.targetUnavailable.rawValue:
            disposition = .targetUnavailable
        case ForgeRuntimeSemanticInteractionDisposition.unsupportedByProject.rawValue:
            disposition = .unsupportedByProject
        default:
            // `runtimeUnavailable` is deliberately host-owned: generated-page JavaScript cannot
            // manufacture evidence that the native runtime process/navigation itself was absent.
            throw ForgeRuntimeWebSemanticAutomationError.unsupportedDisposition(result.disposition)
        }

        return authorized.receipt(disposition: disposition)
    }
}
