import Foundation

public struct AgentBudgetLimits: Codable, Equatable, Sendable {
    public var iterations: UInt64
    public var providerAttempts: UInt64
    public var retries: UInt64
    public var toolInvocations: UInt64
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var elapsedMilliseconds: UInt64
    public var costMicrounits: UInt64
    public var childRuns: UInt64
    public var childDepth: UInt16

    public init(
        iterations: UInt64,
        providerAttempts: UInt64,
        retries: UInt64,
        toolInvocations: UInt64,
        inputTokens: UInt64,
        outputTokens: UInt64,
        elapsedMilliseconds: UInt64,
        costMicrounits: UInt64,
        childRuns: UInt64,
        childDepth: UInt16
    ) {
        self.iterations = iterations
        self.providerAttempts = providerAttempts
        self.retries = retries
        self.toolInvocations = toolInvocations
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.elapsedMilliseconds = elapsedMilliseconds
        self.costMicrounits = costMicrounits
        self.childRuns = childRuns
        self.childDepth = childDepth
    }

    public static let standard = AgentBudgetLimits(
        iterations: 32,
        providerAttempts: 48,
        retries: 8,
        toolInvocations: 64,
        inputTokens: 1_000_000,
        outputTokens: 250_000,
        elapsedMilliseconds: 3_600_000,
        costMicrounits: 100_000_000,
        childRuns: 16,
        childDepth: 4
    )
}

public struct AgentBudgetUsage: Codable, Equatable, Sendable {
    public var iterations: UInt64
    public var providerAttempts: UInt64
    public var retries: UInt64
    public var toolInvocations: UInt64
    public var inputTokens: UInt64
    public var outputTokens: UInt64
    public var elapsedMilliseconds: UInt64
    public var costMicrounits: UInt64
    public var childRuns: UInt64

    public init(
        iterations: UInt64 = 0,
        providerAttempts: UInt64 = 0,
        retries: UInt64 = 0,
        toolInvocations: UInt64 = 0,
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        elapsedMilliseconds: UInt64 = 0,
        costMicrounits: UInt64 = 0,
        childRuns: UInt64 = 0
    ) {
        self.iterations = iterations
        self.providerAttempts = providerAttempts
        self.retries = retries
        self.toolInvocations = toolInvocations
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.elapsedMilliseconds = elapsedMilliseconds
        self.costMicrounits = costMicrounits
        self.childRuns = childRuns
    }

    public static let zero = AgentBudgetUsage()
}

public enum AgentBudgetDimension: String, Codable, CaseIterable, Hashable, Sendable {
    case iterations
    case providerAttempts
    case retries
    case toolInvocations
    case inputTokens
    case outputTokens
    case elapsedMilliseconds
    case costMicrounits
    case childRuns
}

public enum AgentBudgetArithmeticError: Error, Equatable, Sendable {
    case overflow(AgentBudgetDimension)
}

public struct AgentBudget: Codable, Equatable, Sendable {
    public let limits: AgentBudgetLimits
    public private(set) var usage: AgentBudgetUsage

    public init(limits: AgentBudgetLimits, usage: AgentBudgetUsage = .zero) {
        self.limits = limits
        self.usage = usage
    }

    public var exhaustedDimensions: [AgentBudgetDimension] {
        var dimensions: [AgentBudgetDimension] = []
        if usage.iterations >= limits.iterations { dimensions.append(.iterations) }
        if usage.providerAttempts >= limits.providerAttempts { dimensions.append(.providerAttempts) }
        if usage.retries >= limits.retries { dimensions.append(.retries) }
        if usage.toolInvocations >= limits.toolInvocations { dimensions.append(.toolInvocations) }
        if usage.inputTokens >= limits.inputTokens { dimensions.append(.inputTokens) }
        if usage.outputTokens >= limits.outputTokens { dimensions.append(.outputTokens) }
        if usage.elapsedMilliseconds >= limits.elapsedMilliseconds { dimensions.append(.elapsedMilliseconds) }
        if usage.costMicrounits >= limits.costMicrounits { dimensions.append(.costMicrounits) }
        if usage.childRuns >= limits.childRuns { dimensions.append(.childRuns) }
        return dimensions
    }

    public var exceededDimensions: [AgentBudgetDimension] {
        var dimensions: [AgentBudgetDimension] = []
        if usage.iterations > limits.iterations { dimensions.append(.iterations) }
        if usage.providerAttempts > limits.providerAttempts { dimensions.append(.providerAttempts) }
        if usage.retries > limits.retries { dimensions.append(.retries) }
        if usage.toolInvocations > limits.toolInvocations { dimensions.append(.toolInvocations) }
        if usage.inputTokens > limits.inputTokens { dimensions.append(.inputTokens) }
        if usage.outputTokens > limits.outputTokens { dimensions.append(.outputTokens) }
        if usage.elapsedMilliseconds > limits.elapsedMilliseconds { dimensions.append(.elapsedMilliseconds) }
        if usage.costMicrounits > limits.costMicrounits { dimensions.append(.costMicrounits) }
        if usage.childRuns > limits.childRuns { dimensions.append(.childRuns) }
        return dimensions
    }

    public func applying(_ delta: AgentBudgetUsage) throws -> Self {
        var next = self
        next.usage.iterations = try adding(usage.iterations, delta.iterations, .iterations)
        next.usage.providerAttempts = try adding(usage.providerAttempts, delta.providerAttempts, .providerAttempts)
        next.usage.retries = try adding(usage.retries, delta.retries, .retries)
        next.usage.toolInvocations = try adding(usage.toolInvocations, delta.toolInvocations, .toolInvocations)
        next.usage.inputTokens = try adding(usage.inputTokens, delta.inputTokens, .inputTokens)
        next.usage.outputTokens = try adding(usage.outputTokens, delta.outputTokens, .outputTokens)
        next.usage.elapsedMilliseconds = try adding(usage.elapsedMilliseconds, delta.elapsedMilliseconds, .elapsedMilliseconds)
        next.usage.costMicrounits = try adding(usage.costMicrounits, delta.costMicrounits, .costMicrounits)
        next.usage.childRuns = try adding(usage.childRuns, delta.childRuns, .childRuns)
        return next
    }

    private func adding(
        _ lhs: UInt64,
        _ rhs: UInt64,
        _ dimension: AgentBudgetDimension
    ) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw AgentBudgetArithmeticError.overflow(dimension)
        }
        return result.partialValue
    }
}
