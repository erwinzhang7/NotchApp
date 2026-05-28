import Foundation

struct CodexUsageReader {
    private struct RawUsage {
        let input: Int
        let cachedInput: Int
        let output: Int
        let reasoningOutput: Int
        let total: Int
    }

    func loadEvents() -> TokenUsageLoadResult {
        var result = TokenUsageLoadResult()
        let roots = codexSessionRoots()

        if roots.isEmpty {
            result.warnings.append("No Codex JSONL directories found.")
            return result
        }

        var fallbackFileCount = 0
        for root in roots {
            for file in TokenUsageJSONL.jsonlFiles(in: root) {
                result.filesScanned += 1
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                let sessionID = relative.replacingOccurrences(of: ".jsonl", with: "")
                var previousTotals: RawUsage?
                var currentModel: String?
                var currentModelIsFallback = false
                var usedFallbackInFile = false

                TokenUsageJSONL.lines(in: file) { line in
                    guard line.contains("turn_context") || line.contains("token_count"),
                          let object = TokenUsageJSONL.parseJSONObject(line),
                          let entryType = TokenUsageJSONL.stringValue(object["type"])
                    else {
                        return
                    }

                    let payload = TokenUsageJSONL.dictionary(object["payload"])
                    if entryType == "turn_context" {
                        if let model = extractModel(from: payload) {
                            currentModel = model
                            currentModelIsFallback = false
                        }
                        return
                    }

                    guard entryType == "event_msg",
                          payload?["type"] as? String == "token_count",
                          let timestamp = TokenUsageJSONL.parseDate(object["timestamp"]),
                          let info = TokenUsageJSONL.dictionary(payload?["info"])
                    else {
                        return
                    }

                    let lastUsage = rawUsage(info["last_token_usage"])
                    let totalUsage = rawUsage(info["total_token_usage"])
                    let usage = lastUsage ?? totalUsage.map { subtract($0, previousTotals) }
                    if let totalUsage {
                        previousTotals = totalUsage
                    }
                    guard let usage else { return }

                    let cached = min(usage.cachedInput, usage.input)
                    guard usage.input > 0 || cached > 0 || usage.output > 0 || usage.reasoningOutput > 0 else {
                        return
                    }

                    let extractedModel = extractModel(from: payload)
                    var isFallbackModel = false
                    if let extractedModel {
                        currentModel = extractedModel
                        currentModelIsFallback = false
                    }

                    var model = extractedModel ?? currentModel
                    if model == nil {
                        model = "gpt-5"
                        isFallbackModel = true
                        currentModel = model
                        currentModelIsFallback = true
                        usedFallbackInFile = true
                    } else if extractedModel == nil && currentModelIsFallback {
                        isFallbackModel = true
                    }

                    result.events.append(TokenUsageEvent(
                        source: .codex,
                        timestamp: timestamp,
                        sessionID: sessionID,
                        project: nil,
                        model: model ?? "unknown",
                        speed: nil,
                        inputTokens: usage.input,
                        outputTokens: usage.output,
                        cacheCreationTokens: 0,
                        cacheCreation5mTokens: 0,
                        cacheCreation1hTokens: 0,
                        cacheReadTokens: cached,
                        reasoningOutputTokens: usage.reasoningOutput,
                        totalTokens: usage.total,
                        estimatedCostUSD: nil,
                        isFallbackModel: isFallbackModel
                    ))
                }

                if usedFallbackInFile {
                    fallbackFileCount += 1
                }
            }
        }

        if fallbackFileCount > 0 {
            result.warnings.append("Codex model metadata was missing in \(fallbackFileCount) file(s); gpt-5 fallback pricing will be approximate.")
        }
        return result
    }

    private func codexSessionRoots() -> [URL] {
        let homes: [URL]
        if let configured = TokenUsageJSONL.environment("CODEX_HOME") {
            homes = configured
                .split(separator: ",")
                .map { TokenUsageJSONL.expandHome(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            homes = [TokenUsageJSONL.homeDirectory.appendingPathComponent(".codex")]
        }

        let roots = homes.map { home -> URL in
            let sessions = home.appendingPathComponent("sessions")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return sessions
            }
            return home
        }

        return TokenUsageJSONL.existingDirectories(roots)
    }

    private func rawUsage(_ value: Any?) -> RawUsage? {
        guard let object = TokenUsageJSONL.dictionary(value) else { return nil }
        let input = TokenUsageJSONL.intValue(object["input_tokens"])
        let cachedInput = TokenUsageJSONL.intValue(object["cached_input_tokens"] ?? object["cache_read_input_tokens"])
        let output = TokenUsageJSONL.intValue(object["output_tokens"])
        let reasoningOutput = TokenUsageJSONL.intValue(object["reasoning_output_tokens"])
        let explicitTotal = TokenUsageJSONL.intValue(object["total_tokens"])
        return RawUsage(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoningOutput: reasoningOutput,
            total: explicitTotal > 0 ? explicitTotal : input + output
        )
    }

    private func subtract(_ current: RawUsage, _ previous: RawUsage?) -> RawUsage {
        RawUsage(
            input: max(current.input - (previous?.input ?? 0), 0),
            cachedInput: max(current.cachedInput - (previous?.cachedInput ?? 0), 0),
            output: max(current.output - (previous?.output ?? 0), 0),
            reasoningOutput: max(current.reasoningOutput - (previous?.reasoningOutput ?? 0), 0),
            total: max(current.total - (previous?.total ?? 0), 0)
        )
    }

    private func extractModel(from value: Any?) -> String? {
        guard let payload = TokenUsageJSONL.dictionary(value) else { return nil }
        if let model = TokenUsageJSONL.stringValue(payload["model"]) {
            return model
        }
        if let metadata = TokenUsageJSONL.dictionary(payload["metadata"]),
           let model = TokenUsageJSONL.stringValue(metadata["model"]) {
            return model
        }
        if let info = TokenUsageJSONL.dictionary(payload["info"]) {
            if let model = TokenUsageJSONL.stringValue(info["model"] ?? info["model_name"]) {
                return model
            }
            if let metadata = TokenUsageJSONL.dictionary(info["metadata"]),
               let model = TokenUsageJSONL.stringValue(metadata["model"]) {
                return model
            }
        }
        return nil
    }
}

