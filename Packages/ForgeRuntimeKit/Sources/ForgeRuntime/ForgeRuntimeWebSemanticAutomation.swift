import Foundation

/// Stable DOM/event names used by Forge Runtime web projects that opt into semantic automation.
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

/// Host-created JavaScript dispatch plan for one gate-authorized interaction.
public struct ForgeRuntimeWebSemanticDispatchPlan: Equatable, Sendable {
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let sequence: Int
    public let javaScript: String

    init(request: ForgeRuntimeSemanticInteractionRequest, javaScript: String) {
        self.requestID = request.requestID
        self.sessionID = request.sessionID
        self.projectID = request.projectID
        self.sourceRevision = request.sourceRevision
        self.sequence = request.sequence
        self.javaScript = javaScript
    }
}

private struct ForgeRuntimeWebSemanticCommand: Encodable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let sessionID: String
    let projectID: String
    let sourceRevision: String
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
    let sourceRevision: String
    let sequence: Int
    let kind: String
    let disposition: String
}

/// Page-reported dispatch status. This is candidate observation data only: decoded/page-authored
/// bytes cannot become authoritative runtime evidence without a real host/WebKit producer binding.
public enum ForgeRuntimeWebSemanticCandidateDisposition: String, Codable, CaseIterable, Sendable {
    case delivered
    case targetUnavailable
    case unsupportedByProject
}

/// Persistable candidate observation of a semantic web dispatch.
///
/// The value proves only that the adapter parsed an identity-matching page result supplied by its
/// caller. It does not prove WebKit process/navigation identity, actual execution, gameplay success,
/// or acceptance. A later host-owned runtime evidence producer must bind real execution state.
public struct ForgeRuntimeWebSemanticDispatchObservation: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let sequence: Int
    public let kind: ForgeRuntimeSemanticInteractionKind
    public let candidateDisposition: ForgeRuntimeWebSemanticCandidateDisposition

    init(
        request: ForgeRuntimeSemanticInteractionRequest,
        candidateDisposition: ForgeRuntimeWebSemanticCandidateDisposition
    ) {
        self.protocolVersion = request.protocolVersion
        self.requestID = request.requestID
        self.sessionID = request.sessionID
        self.projectID = request.projectID
        self.sourceRevision = request.sourceRevision
        self.sequence = request.sequence
        self.kind = request.interaction.kind
        self.candidateDisposition = candidateDisposition
    }
}

/// Pure-Foundation command/result adapter for a web artifact.
///
/// The app host must install `bootstrapJavaScript` at document start and evaluate dispatch plans in
/// a host-controlled isolated WebKit content world. This package deliberately cannot mint trusted
/// runtime-delivery evidence because it has no WebKit process/navigation authority.
public struct ForgeRuntimeWebSemanticAutomationAdapter: Sendable {
    public static let maximumBridgeResultUTF8Bytes = 8 * 1024

    public init() {}

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
        sourceRevision: command.sourceRevision,
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
        try { command = decode(encoded); }
        catch (_) { return '__NOVAFORGE_INVALID_SEMANTIC_COMMAND__'; }

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
            sourceRevision: request.sourceRevision,
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

    /// Parses an identity-matching page result into candidate observation only.
    /// The caller must not use this value as trusted runtime/Completion evidence.
    public func observeDispatchResult(
        for authorized: ForgeRuntimeAuthorizedSemanticInteraction,
        bridgeResultJSON: String
    ) throws -> ForgeRuntimeWebSemanticDispatchObservation {
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
        do { result = try JSONDecoder().decode(ForgeRuntimeWebSemanticResult.self, from: resultBytes) }
        catch { throw ForgeRuntimeWebSemanticAutomationError.invalidBridgeResult }

        let request = authorized.request
        guard result.protocolVersion == request.protocolVersion,
              result.requestID == request.requestID,
              result.sessionID == request.sessionID,
              result.projectID == request.projectID,
              result.sourceRevision == request.sourceRevision,
              result.sequence == request.sequence,
              result.kind == request.interaction.kind.rawValue else {
            throw ForgeRuntimeWebSemanticAutomationError.resultIdentityMismatch
        }

        guard let disposition = ForgeRuntimeWebSemanticCandidateDisposition(rawValue: result.disposition) else {
            throw ForgeRuntimeWebSemanticAutomationError.unsupportedDisposition(result.disposition)
        }
        return .init(request: request, candidateDisposition: disposition)
    }
}
