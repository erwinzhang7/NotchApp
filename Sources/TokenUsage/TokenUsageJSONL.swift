import Foundation

enum TokenUsageJSONL {
    static let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func environment(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func expandHome(_ path: String) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    static func existingDirectories(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func jsonlFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
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

    /// Calls `handle` with each non-empty line of `file` as raw bytes. Lines
    /// stay as `Data` so callers can reject them with `contains(_:in:)`
    /// before paying for a String or a JSON parse; most bytes in these logs
    /// are tool output that never carries usage.
    ///
    /// Each line is handled inside its own autorelease pool. The readers run
    /// as one long job off the main thread, and JSONSerialization returns
    /// autoreleased Foundation objects: without the pool every dictionary
    /// from every line of every file stays alive until the whole scan ends,
    /// which over a few GB of logs is gigabytes of footprint.
    static func lines(in file: URL, handle: (Data) -> Void) {
        guard let stream = InputStream(url: file) else { return }
        stream.open()
        defer { stream.close() }

        let bufferSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pending = Data()

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count <= 0 { break }
            // Only scan the new bytes for newlines; the old tail has none.
            var searchFrom = pending.count
            pending.append(buffer, count: count)

            var lineStart = 0
            while let newline = firstNewline(in: pending, from: searchFrom) {
                if newline > lineStart {
                    autoreleasepool { handle(pending[lineStart..<newline]) }
                }
                lineStart = newline + 1
                searchFrom = lineStart
            }
            // Drop consumed lines once per chunk, not once per line.
            if lineStart > 0 {
                pending.removeSubrange(0..<lineStart)
            }
        }

        if !pending.isEmpty {
            autoreleasepool { handle(pending) }
        }
    }

    private static func firstNewline(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            guard let hit = memchr(base + offset, 0x0A, raw.count - offset) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// Byte-level substring test for a line from `lines(in:handle:)`.
    static func contains(_ needle: String, in line: Data) -> Bool {
        var needle = needle
        return needle.withUTF8 { pattern in
            line.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, let pat = pattern.baseAddress else { return false }
                return memmem(base, raw.count, pat, pattern.count) != nil
            }
        }
    }

    static func parseJSONObject(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string)
    }

    static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

