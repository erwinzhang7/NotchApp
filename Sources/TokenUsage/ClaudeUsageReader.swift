import Foundation

struct ClaudeUsageReader {
    func loadEvents() -> TokenUsageLoadResult {
        var result = TokenUsageLoadResult()
        // Maps a messageId:requestId hash to its index in `result.events`.
        // Claude writes several `usage` lines per assistant turn — partial
        // streaming snapshots that share one message id + request id — and
        // only the LAST carries the cumulative output. Keeping the first
        // (as before) undercounted output by ~12%. Match ccusage: keep the
        // last entry for each hash by overwriting in place.
        var indexByHash: [String: Int] = [:]
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

                    let event = TokenUsageEvent(
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
                    )

                    // Keep the last entry per messageId:requestId (cumulative
                    // usage); entries lacking either id can't be deduped and
                    // are always appended.
                    if let messageID = TokenUsageJSONL.stringValue(message["id"]),
                       let requestID = TokenUsageJSONL.stringValue(object["requestId"]) {
                        let hash = "\(messageID):\(requestID)"
                        if let index = indexByHash[hash] {
                            result.events[index] = event
                        } else {
                            indexByHash[hash] = result.events.count
                            result.events.append(event)
                        }
                    } else {
                        result.events.append(event)
                    }
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

