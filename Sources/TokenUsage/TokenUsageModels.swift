import Foundation

enum TokenUsageSource: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

struct TokenUsageTotals: Codable, Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var cacheReadTokens: Int = 0
    var reasoningOutputTokens: Int = 0
    var totalTokens: Int = 0
    var estimatedCostUSD: Double = 0

    mutating func add(_ event: TokenUsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheCreationTokens += event.cacheCreationTokens
        cacheCreation5mTokens += event.cacheCreation5mTokens
        cacheCreation1hTokens += event.cacheCreation1hTokens
        cacheReadTokens += event.cacheReadTokens
        reasoningOutputTokens += event.reasoningOutputTokens
        totalTokens += event.totalTokens
        estimatedCostUSD += event.estimatedCostUSD ?? 0
    }
}

struct TokenUsageEvent: Equatable, Sendable {
    let source: TokenUsageSource
    let timestamp: Date
    let sessionID: String
    let project: String?
    let model: String
    let speed: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int
    let cacheReadTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    var estimatedCostUSD: Double?
    let isFallbackModel: Bool
}

struct TokenUsageSnapshot: Equatable, Sendable {
    var generatedAt: Date = Date()
    var filesScanned: Int = 0
    var eventsLoaded: Int = 0
    var totals = TokenUsageTotals()
    var bySource: [TokenUsageSource: TokenUsageTotals] = [:]
    var byDay: [String: TokenUsageTotals] = [:]
    var byModel: [String: TokenUsageTotals] = [:]
    var periodTotals: [TokenUsageSource: TokenUsagePeriodTotals] = [:]
    var warnings: [String] = []
}

struct TokenUsagePeriodTotals: Equatable, Sendable {
    var daily = TokenUsageTotals()
    var weekly = TokenUsageTotals()
    var monthly = TokenUsageTotals()
}

struct TokenUsageLoadResult: Sendable {
    var events: [TokenUsageEvent] = []
    var filesScanned: Int = 0
    var warnings: [String] = []
}
