import Foundation

struct ClaudeUsageReader {
    func loadEvents() -> TokenUsageLoadResult {
        var result = TokenUsageLoadResult()
        var processedHashes = Set<String>()
        let roots = claudeRoots()

        if roots.isEmpty {
            result.warnings.append("No Claude JSONL directories found.")
            return result
        }

        for root in roots {
            for file in TokenUsageJSONL.jsonlFiles(in: root) {
                result.filesScanned += 1
                let project = projectName(for: file, root: root)

                TokenUsageJSONL.lines(in: file) { line in
                    guard line.contains("\"usage\""),
                          let object = TokenUsageJSONL.parseJSONObject(line),
                          let timestamp = TokenUsageJSONL.parseDate(object["timestamp"]),
                          let message = TokenUsageJSONL.dictionary(object["message"]),
                          let usage = TokenUsageJSONL.dictionary(message["usage"])
                    else {
                        return
                    }

                    if let messageID = TokenUsageJSONL.stringValue(message["id"]),
                       let requestID = TokenUsageJSONL.stringValue(object["requestId"]) {
                        let hash = "\(messageID):\(requestID)"
                        guard !processedHashes.contains(hash) else { return }
                        processedHashes.insert(hash)
                    }

                    let input = TokenUsageJSONL.intValue(usage["input_tokens"])
                    let output = TokenUsageJSONL.intValue(usage["output_tokens"])
                    let cacheCreationTotal = TokenUsageJSONL.intValue(usage["cache_creation_input_tokens"])
                    let cacheRead = TokenUsageJSONL.intValue(usage["cache_read_input_tokens"])
                    let cacheCreation = TokenUsageJSONL.dictionary(usage["cache_creation"])
                    let cacheCreation5m = TokenUsageJSONL.intValue(cacheCreation?["ephemeral_5m_input_tokens"])
                    let cacheCreation1h = TokenUsageJSONL.intValue(cacheCreation?["ephemeral_1h_input_tokens"])
                    let apportionedCacheTotal = cacheCreation5m + cacheCreation1h
                    let normalizedCacheCreation = cacheCreationTotal > 0 ? cacheCreationTotal : apportionedCacheTotal
                    let normalized5m = apportionedCacheTotal > 0 ? cacheCreation5m : normalizedCacheCreation
                    let normalized1h = apportionedCacheTotal > 0 ? cacheCreation1h : 0
                    let total = input + output + normalizedCacheCreation + cacheRead
                    guard total > 0 else { return }

                    let rawModel = TokenUsageJSONL.stringValue(message["model"]) ?? "unknown"
                    let speed = TokenUsageJSONL.stringValue(usage["speed"])
                    let displayModel = speed == "fast" ? "\(rawModel)-fast" : rawModel

                    result.events.append(TokenUsageEvent(
                        source: .claude,
                        timestamp: timestamp,
                        sessionID: TokenUsageJSONL.stringValue(object["sessionId"]) ?? file.deletingPathExtension().lastPathComponent,
                        project: project,
                        model: displayModel,
                        speed: speed,
                        inputTokens: input,
                        outputTokens: output,
                        cacheCreationTokens: normalizedCacheCreation,
                        cacheCreation5mTokens: normalized5m,
                        cacheCreation1hTokens: normalized1h,
                        cacheReadTokens: cacheRead,
                        reasoningOutputTokens: 0,
                        totalTokens: total,
                        estimatedCostUSD: TokenUsageJSONL.doubleValue(object["costUSD"]),
                        isFallbackModel: false
                    ))
                }
            }
        }

        return result
    }

    private func claudeRoots() -> [URL] {
        if let configured = TokenUsageJSONL.environment("CLAUDE_CONFIG_DIR") {
            return TokenUsageJSONL.existingDirectories(
                configured
                    .split(separator: ",")
                    .map { TokenUsageJSONL.expandHome(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .map { $0.appendingPathComponent("projects") }
            )
        }

        return TokenUsageJSONL.existingDirectories([
            TokenUsageJSONL.homeDirectory.appendingPathComponent(".config/claude/projects"),
            TokenUsageJSONL.homeDirectory.appendingPathComponent(".claude/projects")
        ])
    }

    private func projectName(for file: URL, root: URL) -> String? {
        let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
        return relative.split(separator: "/").first.map(String.init)
    }
}

