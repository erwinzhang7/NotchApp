import Foundation

struct LiteLLMModelPricing: Codable, Equatable, Sendable {
    struct ProviderSpecificEntry: Codable, Equatable, Sendable {
        let fast: Double?
    }

    let inputCostPerToken: Double?
    let outputCostPerToken: Double?
    let cacheCreationInputTokenCost: Double?
    let cacheReadInputTokenCost: Double?
    let inputCostPerTokenAbove200k: Double?
    let outputCostPerTokenAbove200k: Double?
    let cacheCreationInputTokenCostAbove200k: Double?
    let cacheReadInputTokenCostAbove200k: Double?
    let providerSpecificEntry: ProviderSpecificEntry?

    enum CodingKeys: String, CodingKey {
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
        case cacheReadInputTokenCost = "cache_read_input_token_cost"
        case inputCostPerTokenAbove200k = "input_cost_per_token_above_200k_tokens"
        case outputCostPerTokenAbove200k = "output_cost_per_token_above_200k_tokens"
        case cacheCreationInputTokenCostAbove200k = "cache_creation_input_token_cost_above_200k_tokens"
        case cacheReadInputTokenCostAbove200k = "cache_read_input_token_cost_above_200k_tokens"
        case providerSpecificEntry = "provider_specific_entry"
    }
}

actor TokenPricingCache {
    private struct StoredPricing: Codable {
        let fetchedAt: Date
        let models: [String: LiteLLMModelPricing]
    }

    private static let pricingURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let cacheURL: URL
    private var models: [String: LiteLLMModelPricing] = [:]
    private var fetchedAt: Date?

    init() {
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("NotchApp", isDirectory: true)
            ?? TokenUsageJSONL.homeDirectory.appendingPathComponent("Library/Application Support/NotchApp", isDirectory: true)
        self.cacheURL = supportDirectory.appendingPathComponent("token-pricing.json")
    }

    func loadCachedPricing() {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode(StoredPricing.self, from: data)
        else {
            return
        }
        self.models = stored.models
        self.fetchedAt = stored.fetchedAt
    }

    func refreshIfNeeded(now: Date = Date(), force: Bool = false) async {
        loadCachedPricing()
        if !force, let fetchedAt, Calendar.current.isDate(fetchedAt, inSameDayAs: now) {
            return
        }
        await refresh()
    }

    func refresh() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.pricingURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("[TokenUsage] Pricing fetch failed: non-200 response")
                return
            }
            let decoded = try JSONDecoder().decode([String: LiteLLMModelPricing].self, from: data)
            self.models = decoded
            self.fetchedAt = Date()
            try persist()
            NSLog("[TokenUsage] Refreshed LiteLLM pricing for \(decoded.count) models")
        } catch {
            NSLog("[TokenUsage] Pricing fetch failed: \(error.localizedDescription)")
        }
    }

    func pricing(for model: String) -> LiteLLMModelPricing? {
        if models.isEmpty {
            loadCachedPricing()
        }
        if let direct = models[model] {
            return direct
        }

        for candidate in matchingCandidates(for: model) {
            if let pricing = models[candidate] {
                return pricing
            }
        }

        let lower = model.lowercased()
        var best: (pricing: LiteLLMModelPricing, lengthDiff: Int)?
        for (key, pricing) in models {
            let comparison = key.lowercased()
            guard comparison.contains(lower) || lower.contains(comparison) else { continue }
            let diff = abs(comparison.count - lower.count)
            if best == nil || diff < best!.lengthDiff {
                best = (pricing, diff)
            }
        }
        return best?.pricing
    }

    func estimatedCost(for event: TokenUsageEvent) -> Double? {
        guard let pricing = pricing(for: normalizedModelName(event.model)) else {
            return event.estimatedCostUSD
        }

        let inputCost = tieredCost(
            tokens: event.inputTokens,
            base: pricing.inputCostPerToken,
            above200k: pricing.inputCostPerTokenAbove200k
        )
        let outputCost = tieredCost(
            tokens: event.outputTokens,
            base: pricing.outputCostPerToken,
            above200k: pricing.outputCostPerTokenAbove200k
        )
        let cacheCreationCost = tieredCost(
            tokens: event.cacheCreationTokens,
            base: pricing.cacheCreationInputTokenCost,
            above200k: pricing.cacheCreationInputTokenCostAbove200k
        )
        let cacheReadCost = tieredCost(
            tokens: event.cacheReadTokens,
            base: pricing.cacheReadInputTokenCost,
            above200k: pricing.cacheReadInputTokenCostAbove200k
        )
        let multiplier = event.speed == "fast" ? (pricing.providerSpecificEntry?.fast ?? 1) : 1
        return (inputCost + outputCost + cacheCreationCost + cacheReadCost) * multiplier
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = StoredPricing(fetchedAt: fetchedAt ?? Date(), models: models)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func matchingCandidates(for model: String) -> [String] {
        [
            model,
            "anthropic/\(model)",
            "claude-3-5-\(model)",
            "claude-3-\(model)",
            "claude-\(model)",
            "openai/\(model)",
            "azure/\(model)",
            "openrouter/openai/\(model)"
        ]
    }

    private func normalizedModelName(_ model: String) -> String {
        model.hasSuffix("-fast") ? String(model.dropLast("-fast".count)) : model
    }

    private func tieredCost(tokens: Int, base: Double?, above200k: Double?) -> Double {
        guard tokens > 0 else { return 0 }
        if tokens > 200_000, let above200k {
            let baseCost = Double(min(tokens, 200_000)) * (base ?? 0)
            return baseCost + Double(tokens - 200_000) * above200k
        }
        return Double(tokens) * (base ?? 0)
    }
}
