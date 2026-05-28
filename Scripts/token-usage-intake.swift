#!/usr/bin/env swift

import Foundation

enum Source: String, Codable {
    case claude
    case codex
}

struct TokenTotals: Codable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var reasoningOutputTokens = 0
    var totalTokens = 0
    var estimatedCostUSD = 0.0

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheCreationTokens += event.cacheCreationTokens
        cacheReadTokens += event.cacheReadTokens
        reasoningOutputTokens += event.reasoningOutputTokens
        totalTokens += event.totalTokens
        estimatedCostUSD += event.estimatedCostUSD ?? 0
    }
}

struct UsageEvent {
    let source: Source
    let timestamp: Date
    let sessionID: String
    let project: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Double?
    let isFallbackModel: Bool
}

struct Summary: Codable {
    let generatedAt: String
    let filesScanned: Int
    let eventsLoaded: Int
    let totals: TokenTotals
    let bySource: [String: TokenTotals]
    let byDay: [String: TokenTotals]
    let byModel: [String: TokenTotals]
    let warnings: [String]
}

let fileManager = FileManager.default
let homeDirectory = fileManager.homeDirectoryForCurrentUser
let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

let fallbackISOFormatter = ISO8601DateFormatter()
fallbackISOFormatter.formatOptions = [.withInternetDateTime]

let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

let prettyOutput = CommandLine.arguments.contains("--pretty")
let includeEvents = CommandLine.arguments.contains("--events")

func env(_ name: String) -> String? {
    let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}

func expandHome(_ path: String) -> URL {
    if path == "~" {
        return homeDirectory
    }
    if path.hasPrefix("~/") {
        return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path)
}

func existingDirectories(_ urls: [URL]) -> [URL] {
    urls.filter { url in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

func jsonlFiles(in directory: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
        files.append(url)
    }
    return files.sorted { $0.path < $1.path }
}

func parseDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string)
}

func intValue(_ value: Any?) -> Int {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    return 0
}

func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
        return double
    }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func parseJSONObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func lines(in file: URL, handle: (String) -> Void) {
    guard let stream = InputStream(url: file) else { return }
    stream.open()
    defer { stream.close() }

    let bufferSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var pending = Data()

    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: bufferSize)
        if count <= 0 { break }
        pending.append(buffer, count: count)

        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newline]
            pending.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                handle(line)
            }
        }
    }

    if !pending.isEmpty, let line = String(data: pending, encoding: .utf8), !line.isEmpty {
        handle(line)
    }
}

func claudeRoots() -> [URL] {
    if let configured = env("CLAUDE_CONFIG_DIR") {
        return existingDirectories(
            configured
                .split(separator: ",")
                .map { expandHome(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                .map { $0.appendingPathComponent("projects") }
        )
    }

    return existingDirectories([
        homeDirectory.appendingPathComponent(".config/claude/projects"),
        homeDirectory.appendingPathComponent(".claude/projects")
    ])
}

func projectName(forClaudeFile file: URL, root: URL) -> String? {
    let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
    return relative.split(separator: "/").first.map(String.init)
}

func loadClaudeEvents() -> (events: [UsageEvent], files: Int) {
    var events: [UsageEvent] = []
    var processedHashes = Set<String>()
    var fileCount = 0

    for root in claudeRoots() {
        for file in jsonlFiles(in: root) {
            fileCount += 1
            let project = projectName(forClaudeFile: file, root: root)

            lines(in: file) { line in
                guard line.contains("\"usage\""),
                      let object = parseJSONObject(line),
                      let timestamp = parseDate(object["timestamp"]),
                      let message = dictionary(object["message"]),
                      let usage = dictionary(message["usage"])
                else {
                    return
                }

                if let messageID = stringValue(message["id"]),
                   let requestID = stringValue(object["requestId"]) {
                    let hash = "\(messageID):\(requestID)"
                    guard !processedHashes.contains(hash) else { return }
                    processedHashes.insert(hash)
                }

                let input = intValue(usage["input_tokens"])
                let output = intValue(usage["output_tokens"])
                let cacheCreation = intValue(usage["cache_creation_input_tokens"])
                let cacheRead = intValue(usage["cache_read_input_tokens"])
                let total = input + output + cacheCreation + cacheRead
                guard total > 0 else { return }

                let rawModel = stringValue(message["model"]) ?? "unknown"
                let speed = stringValue(usage["speed"])
                let model = speed == "fast" ? "\(rawModel)-fast" : rawModel

                events.append(UsageEvent(
                    source: .claude,
                    timestamp: timestamp,
                    sessionID: stringValue(object["sessionId"]) ?? file.deletingPathExtension().lastPathComponent,
                    project: project,
                    model: model,
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead,
                    reasoningOutputTokens: 0,
                    totalTokens: total,
                    estimatedCostUSD: doubleValue(object["costUSD"]),
                    isFallbackModel: false
                ))
            }
        }
    }

    return (events, fileCount)
}

struct CodexRawUsage {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoningOutput: Int
    let total: Int
}

func codexRawUsage(_ value: Any?) -> CodexRawUsage? {
    guard let object = dictionary(value) else { return nil }
    let input = intValue(object["input_tokens"])
    let cachedInput = intValue(object["cached_input_tokens"] ?? object["cache_read_input_tokens"])
    let output = intValue(object["output_tokens"])
    let reasoningOutput = intValue(object["reasoning_output_tokens"])
    let explicitTotal = intValue(object["total_tokens"])
    let total = explicitTotal > 0 ? explicitTotal : input + output
    return CodexRawUsage(input: input, cachedInput: cachedInput, output: output, reasoningOutput: reasoningOutput, total: total)
}

func subtract(_ current: CodexRawUsage, _ previous: CodexRawUsage?) -> CodexRawUsage {
    CodexRawUsage(
        input: max(current.input - (previous?.input ?? 0), 0),
        cachedInput: max(current.cachedInput - (previous?.cachedInput ?? 0), 0),
        output: max(current.output - (previous?.output ?? 0), 0),
        reasoningOutput: max(current.reasoningOutput - (previous?.reasoningOutput ?? 0), 0),
        total: max(current.total - (previous?.total ?? 0), 0)
    )
}

func extractCodexModel(from value: Any?) -> String? {
    guard let payload = dictionary(value) else { return nil }
    if let model = stringValue(payload["model"]) {
        return model
    }
    if let metadata = dictionary(payload["metadata"]), let model = stringValue(metadata["model"]) {
        return model
    }
    if let info = dictionary(payload["info"]) {
        if let model = stringValue(info["model"] ?? info["model_name"]) {
            return model
        }
        if let metadata = dictionary(info["metadata"]), let model = stringValue(metadata["model"]) {
            return model
        }
    }
    return nil
}

func codexSessionRoots() -> [URL] {
    let homes: [URL]
    if let configured = env("CODEX_HOME") {
        homes = configured
            .split(separator: ",")
            .map { expandHome(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    } else {
        homes = [homeDirectory.appendingPathComponent(".codex")]
    }

    let roots = homes.map { home -> URL in
        let sessions = home.appendingPathComponent("sessions")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sessions.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return sessions
        }
        return home
    }

    return existingDirectories(roots)
}

func loadCodexEvents() -> (events: [UsageEvent], files: Int, fallbackFiles: Int) {
    var events: [UsageEvent] = []
    var fileCount = 0
    var fallbackFiles = 0

    for root in codexSessionRoots() {
        for file in jsonlFiles(in: root) {
            fileCount += 1
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let sessionID = relative.replacingOccurrences(of: ".jsonl", with: "")
            var previousTotals: CodexRawUsage?
            var currentModel: String?
            var currentModelIsFallback = false
            var usedFallbackInFile = false

            lines(in: file) { line in
                guard line.contains("turn_context") || line.contains("token_count"),
                      let object = parseJSONObject(line),
                      let entryType = stringValue(object["type"])
                else {
                    return
                }

                let payload = dictionary(object["payload"])

                if entryType == "turn_context" {
                    if let model = extractCodexModel(from: payload) {
                        currentModel = model
                        currentModelIsFallback = false
                    }
                    return
                }

                guard entryType == "event_msg",
                      payload?["type"] as? String == "token_count",
                      let timestamp = parseDate(object["timestamp"]),
                      let info = dictionary(payload?["info"])
                else {
                    return
                }

                let lastUsage = codexRawUsage(info["last_token_usage"])
                let totalUsage = codexRawUsage(info["total_token_usage"])
                let rawUsage = lastUsage ?? totalUsage.map { subtract($0, previousTotals) }
                if let totalUsage {
                    previousTotals = totalUsage
                }
                guard let rawUsage else { return }

                let cached = min(rawUsage.cachedInput, rawUsage.input)
                guard rawUsage.input > 0 || cached > 0 || rawUsage.output > 0 || rawUsage.reasoningOutput > 0 else {
                    return
                }

                let extractedModel = extractCodexModel(from: payload)
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

                events.append(UsageEvent(
                    source: .codex,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    project: nil,
                    model: model ?? "unknown",
                    inputTokens: rawUsage.input,
                    outputTokens: rawUsage.output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached,
                    reasoningOutputTokens: rawUsage.reasoningOutput,
                    totalTokens: rawUsage.total,
                    estimatedCostUSD: nil,
                    isFallbackModel: isFallbackModel
                ))
            }

            if usedFallbackInFile {
                fallbackFiles += 1
            }
        }
    }

    return (events, fileCount, fallbackFiles)
}

func aggregate(_ events: [UsageEvent], key: (UsageEvent) -> String) -> [String: TokenTotals] {
    var result: [String: TokenTotals] = [:]
    for event in events {
        var totals = result[key(event)] ?? TokenTotals()
        totals.add(event)
        result[key(event)] = totals
    }
    return result
}

func sortedDictionary(_ dictionary: [String: TokenTotals]) -> [String: TokenTotals] {
    Dictionary(uniqueKeysWithValues: dictionary.sorted { $0.key < $1.key })
}

let claude = loadClaudeEvents()
let codex = loadCodexEvents()
let events = (claude.events + codex.events).sorted { $0.timestamp < $1.timestamp }

var totals = TokenTotals()
for event in events {
    totals.add(event)
}

var warnings: [String] = []
if claude.files == 0 {
    warnings.append("No Claude JSONL files found under CLAUDE_CONFIG_DIR, ~/.config/claude/projects, or ~/.claude/projects.")
}
if codex.files == 0 {
    warnings.append("No Codex JSONL files found under CODEX_HOME or ~/.codex/sessions.")
}
if codex.fallbackFiles > 0 {
    warnings.append("Codex model metadata was missing in \(codex.fallbackFiles) file(s); those events use gpt-5 as a fallback model.")
}

let summary = Summary(
    generatedAt: fallbackISOFormatter.string(from: Date()),
    filesScanned: claude.files + codex.files,
    eventsLoaded: events.count,
    totals: totals,
    bySource: sortedDictionary(aggregate(events) { $0.source.rawValue }),
    byDay: sortedDictionary(aggregate(events) { dayFormatter.string(from: $0.timestamp) }),
    byModel: sortedDictionary(aggregate(events) { "\($0.source.rawValue):\($0.model)" }),
    warnings: warnings
)

let encoder = JSONEncoder()
encoder.outputFormatting = prettyOutput ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]

if includeEvents {
    let eventObjects: [[String: Any]] = events.map { event in
        [
            "source": event.source.rawValue,
            "timestamp": fallbackISOFormatter.string(from: event.timestamp),
            "sessionId": event.sessionID,
            "project": event.project as Any,
            "model": event.model,
            "inputTokens": event.inputTokens,
            "outputTokens": event.outputTokens,
            "cacheCreationTokens": event.cacheCreationTokens,
            "cacheReadTokens": event.cacheReadTokens,
            "reasoningOutputTokens": event.reasoningOutputTokens,
            "totalTokens": event.totalTokens,
            "estimatedCostUSD": event.estimatedCostUSD as Any,
            "isFallbackModel": event.isFallbackModel
        ]
    }
    let object: [String: Any] = [
        "summary": try JSONSerialization.jsonObject(with: encoder.encode(summary)),
        "events": eventObjects
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: prettyOutput ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
} else {
    let data = try encoder.encode(summary)
    print(String(data: data, encoding: .utf8) ?? "{}")
}
