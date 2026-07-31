import Foundation

public enum ProviderFailureCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case cancelled
    case timeout
    case authentication
    case authorization
    case invalidRequest
    case rateLimited
    case contextLimit
    case unavailable
    case transport
    case malformedEvent
    case protocolViolation
    case contentFiltered
    case providerInternal
    case unknown
}

/// Sanitized provider failure. Raw response bodies, credentials, and request content are excluded.
public struct ProviderFailure: Error, Codable, Equatable, Sendable {
    public let category: ProviderFailureCategory
    public let code: String
    public let publicMessage: String
    public let providerID: ProviderID
    public let adapterID: ProviderAdapterID
    public let statusCode: Int?
    public let retryAfterMilliseconds: UInt64?

    public init(
        category: ProviderFailureCategory,
        code: String,
        publicMessage: String,
        providerID: ProviderID,
        adapterID: ProviderAdapterID,
        statusCode: Int? = nil,
        retryAfterMilliseconds: UInt64? = nil
    ) {
        self.category = category
        self.code = code
        self.publicMessage = publicMessage
        self.providerID = providerID
        self.adapterID = adapterID
        self.statusCode = statusCode
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }

    public var retryableOnSameRoute: Bool {
        switch category {
        case .timeout, .rateLimited, .unavailable, .transport, .providerInternal:
            true
        case .cancelled, .authentication, .authorization, .invalidRequest, .contextLimit,
             .malformedEvent, .protocolViolation, .contentFiltered, .unknown:
            false
        }
    }

    public var recoverableByFallback: Bool {
        switch category {
        case .timeout, .rateLimited, .contextLimit, .unavailable, .transport, .providerInternal:
            true
        case .cancelled, .authentication, .authorization, .invalidRequest,
             .malformedEvent, .protocolViolation, .contentFiltered, .unknown:
            false
        }
    }
}

public enum ProviderFailureMapper {
    public static func httpFailure(
        statusCode: Int,
        providerCode: String? = nil,
        providerID: ProviderID,
        adapterID: ProviderAdapterID,
        retryAfterMilliseconds: UInt64? = nil
    ) -> ProviderFailure {
        let normalizedCode = providerCode?.lowercased()
        let category: ProviderFailureCategory
        let stableCode: String

        if normalizedCode == "context_length_exceeded" || normalizedCode == "max_context_length" {
            category = .contextLimit
            stableCode = "provider_context_limit"
        } else if normalizedCode == "content_filter" || normalizedCode == "content_policy_violation" {
            category = .contentFiltered
            stableCode = "provider_content_filtered"
        } else {
            switch statusCode {
            case 400, 404, 405, 409, 413, 422:
                category = .invalidRequest
                stableCode = "provider_invalid_request"
            case 401:
                category = .authentication
                stableCode = "provider_authentication_failed"
            case 402:
                category = .authorization
                stableCode = "provider_payment_required"
            case 403:
                category = .authorization
                stableCode = "provider_authorization_failed"
            case 408, 504:
                category = .timeout
                stableCode = "provider_timeout"
            case 429:
                category = .rateLimited
                stableCode = "provider_rate_limited"
            case 500 ... 503:
                category = .unavailable
                stableCode = "provider_unavailable"
            case 505 ... 599:
                category = .providerInternal
                stableCode = "provider_internal_error"
            default:
                category = .unknown
                stableCode = "provider_http_error"
            }
        }

        return ProviderFailure(
            category: category,
            code: stableCode,
            publicMessage: stableCode == "provider_payment_required"
                ? "The provider needs billing or credits to be configured for this model."
                : publicMessage(for: category),
            providerID: providerID,
            adapterID: adapterID,
            statusCode: statusCode,
            retryAfterMilliseconds: retryAfterMilliseconds
        )
    }

    public static func cancellation(
        providerID: ProviderID,
        adapterID: ProviderAdapterID
    ) -> ProviderFailure {
        ProviderFailure(
            category: .cancelled,
            code: "provider_cancelled",
            publicMessage: publicMessage(for: .cancelled),
            providerID: providerID,
            adapterID: adapterID
        )
    }

    public static func transportFailure(
        providerID: ProviderID,
        adapterID: ProviderAdapterID,
        timedOut: Bool = false
    ) -> ProviderFailure {
        let category: ProviderFailureCategory = timedOut ? .timeout : .transport
        return ProviderFailure(
            category: category,
            code: timedOut ? "provider_timeout" : "provider_transport_failed",
            publicMessage: publicMessage(for: category),
            providerID: providerID,
            adapterID: adapterID
        )
    }

    static func malformed(
        _ code: String,
        descriptor: ProviderAdapterDescriptor,
        message: String = "The provider returned an invalid streaming event."
    ) -> ProviderFailure {
        ProviderFailure(
            category: .malformedEvent,
            code: code,
            publicMessage: message,
            providerID: descriptor.route.providerID,
            adapterID: descriptor.route.adapterID
        )
    }

    static func protocolViolation(
        _ code: String,
        descriptor: ProviderAdapterDescriptor
    ) -> ProviderFailure {
        ProviderFailure(
            category: .protocolViolation,
            code: code,
            publicMessage: "The provider stream violated the adapter contract.",
            providerID: descriptor.route.providerID,
            adapterID: descriptor.route.adapterID
        )
    }

    static func invalidRequest(
        _ code: String,
        descriptor: ProviderAdapterDescriptor,
        message: String
    ) -> ProviderFailure {
        ProviderFailure(
            category: .invalidRequest,
            code: code,
            publicMessage: message,
            providerID: descriptor.route.providerID,
            adapterID: descriptor.route.adapterID
        )
    }

    private static func publicMessage(for category: ProviderFailureCategory) -> String {
        switch category {
        case .cancelled: "The provider request was cancelled."
        case .timeout: "The provider request timed out."
        case .authentication: "Provider authentication failed."
        case .authorization: "The provider rejected this operation."
        case .invalidRequest: "The provider rejected the request."
        case .rateLimited: "The provider is rate limiting requests."
        case .contextLimit: "The request exceeds the model context window."
        case .unavailable: "The provider is temporarily unavailable."
        case .transport: "The provider connection failed."
        case .malformedEvent: "The provider returned an invalid streaming event."
        case .protocolViolation: "The provider stream violated the adapter contract."
        case .contentFiltered: "The provider blocked the response."
        case .providerInternal: "The provider encountered an internal error."
        case .unknown: "The provider request failed."
        }
    }
}
