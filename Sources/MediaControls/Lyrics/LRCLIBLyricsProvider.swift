import CryptoKit
import Foundation

/// LRCLIB.net client. Ported from DynamicNotch and adapted to NotchApp's
/// `LyricsTrackQuery` (DynamicNotch passes a NowPlayingSnapshot struct;
/// our equivalent is a long-lived ObservableObject so the caller builds
/// the query).
///
/// **Performance:** LRCLIB's API is consistently slow: `/api/get` ~5s,
/// `/api/search` ~10s, measured via curl. We work around that with:
/// 1. **Race /get and /search in parallel**. Both fire at once. Happy
///    path returns at /get's pace (~5s); if /get returns 404, the
///    already-running /search lands a few seconds later instead of
///    starting fresh after /get gave up.
/// 2. **Two-layer cache**. In-memory map for the session, plus a JSON
///    disk cache in `~/Library/Caches/.../lyrics/` so re-plays of a
///    song across launches are instant.
@MainActor
final class LRCLIBLyricsProvider {
    private enum CacheEntry {
        case found(TrackLyrics)
        case missing

        var lyrics: TrackLyrics? {
            switch self {
            case .found(let lyrics):
                return lyrics
            case .missing:
                return nil
            }
        }
    }

    /// Result of one of the two race tasks. Distinguishes "no result"
    /// (LRCLIB said this track isn't here) from "errored" (network /
    /// timeout) so the parent can decide whether to throw or cache as
    /// missing.
    private enum RaceOutcome {
        case lyrics(TrackLyrics)
        case notFound
        case error(Error)
    }

    private struct Response: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let baseURL = URL(string: "https://lrclib.net/api")!

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var cache: [String: CacheEntry] = [:]
    private let diskCacheDirectory: URL?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // LRCLIB is genuinely slow: /get typically returns in 5-6s,
        // /search in 8-10s — measured directly with curl. Previous
        // 5s/8s budget was clipping the response right at the
        // boundary, which is why lyrics worked for some tracks and
        // not others (tracks that happened to respond in <5s
        // succeeded; everything else timed out). Bumped to 15s/20s so
        // we have ~2-3× headroom above their observed worst case.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)

        // Disk cache lives under Caches (which macOS may purge under
        // pressure — fine, lyrics are re-fetchable). One file per
        // trackKey, named by SHA256 of the key so weird characters
        // never reach the filesystem layer.
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches
                .appendingPathComponent("com.erwinzhang.NotchApp", isDirectory: true)
                .appendingPathComponent("lyrics", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.diskCacheDirectory = dir
        } else {
            self.diskCacheDirectory = nil
        }
    }

    /// Returns lyrics for `query`, or nil if the track is unknown to
    /// LRCLIB. Throws on transport errors when neither endpoint could
    /// be reached. Caches both hits and misses (memory + disk) so
    /// consecutive lookups of the same track don't re-hit the network.
    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        guard let trackKey = query.cacheKey else { return nil }

        if let cached = cache[trackKey] {
            NSLog("[Lyrics] memory cache HIT trackKey=%@", trackKey)
            return cached.lyrics
        }

        // Disk cache — survives app restart. ~100ms vs network's ~5s.
        if let onDisk = loadFromDisk(trackKey: trackKey) {
            NSLog("[Lyrics] disk cache HIT trackKey=%@", trackKey)
            cache[trackKey] = .found(onDisk)
            return onDisk
        }

        NSLog("[Lyrics] LRCLIB race start trackKey=%@", trackKey)
        let raceStart = Date()

        // Race /get and /search in parallel. Both fire at t=0; we
        // await /get first because it's the faster endpoint when a
        // track has an exact match (~5s). If /get returns lyrics, we
        // return immediately and the still-running /search is
        // implicitly cancelled by async-let scope cleanup. If /get
        // returns nil (album/duration didn't match LRCLIB's record),
        // the /search task has already been running in parallel and
        // is likely close to done — we land at ~10s total instead of
        // the ~15s that strictly-sequential /get→/search would cost.
        async let exactOutcome = race(.exact, query: query, trackKey: trackKey)
        async let searchOutcome = race(.search, query: query, trackKey: trackKey)

        let exact = await exactOutcome
        if case .lyrics(let lyrics) = exact {
            NSLog("[Lyrics] /get won race in %.2fs", Date().timeIntervalSince(raceStart))
            store(trackKey: trackKey, lyrics: lyrics)
            return lyrics
        }

        let search = await searchOutcome
        if case .lyrics(let lyrics) = search {
            NSLog("[Lyrics] /search won fallback in %.2fs", Date().timeIntervalSince(raceStart))
            store(trackKey: trackKey, lyrics: lyrics)
            return lyrics
        }

        // Both nil. If both errored, throw so the caller knows it
        // wasn't a "track not in LRCLIB" miss but a transport problem.
        if case .error(let err) = exact, case .error = search {
            NSLog("[Lyrics] both endpoints errored in %.2fs", Date().timeIntervalSince(raceStart))
            throw err
        }

        NSLog("[Lyrics] LRCLIB no match in %.2fs trackKey=%@",
              Date().timeIntervalSince(raceStart), trackKey)
        cache[trackKey] = .missing
        return nil
    }

    private enum RaceKind { case exact, search }

    /// Single race task wrapper. Maps the underlying fetch's throw /
    /// nil into a non-throwing `RaceOutcome` so async-let can collect
    /// both task results cleanly without forcing the caller into
    /// try-catch-around-each-async-let gymnastics.
    private func race(_ kind: RaceKind, query: LyricsTrackQuery, trackKey: String) async -> RaceOutcome {
        do {
            let result: TrackLyrics?
            switch kind {
            case .exact:
                result = try await fetchExactLyrics(for: query, trackKey: trackKey)
            case .search:
                result = try await searchLyrics(for: query, trackKey: trackKey)
            }
            return result.map(RaceOutcome.lyrics) ?? .notFound
        } catch {
            return .error(error)
        }
    }

    /// Persist lyrics to both caches.
    private func store(trackKey: String, lyrics: TrackLyrics) {
        cache[trackKey] = .found(lyrics)
        saveToDisk(trackKey: trackKey, lyrics: lyrics)
    }

    /// Disk cache filename: SHA256 of the trackKey, hex-encoded.
    /// Avoids any cacheKey character ending up in the filesystem.
    private func diskCacheURL(for trackKey: String) -> URL? {
        guard let dir = diskCacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(trackKey.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func loadFromDisk(trackKey: String) -> TrackLyrics? {
        guard let url = diskCacheURL(for: trackKey),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TrackLyrics.self, from: data)
    }

    private func saveToDisk(trackKey: String, lyrics: TrackLyrics) {
        guard let url = diskCacheURL(for: trackKey),
              let data = try? encoder.encode(lyrics) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Public cache management

    /// Total bytes the on-disk cache is currently using. Walks the
    /// cache directory once; cheap for the cache sizes we ship
    /// (hundreds of entries at most, each a few KB).
    func diskCacheSizeBytes() -> Int {
        guard let dir = diskCacheDirectory else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    /// Wipe memory + disk caches. Subsequent lookups re-fetch from
    /// LRCLIB. Used by the settings "Clear" button.
    func clearCache() {
        cache.removeAll()
        guard let dir = diskCacheDirectory else { return }
        let fm = FileManager.default
        // Remove + recreate so the directory itself stays around for
        // future writes without needing to re-check existence each
        // time. `removeItem` is best-effort — if a file is locked or
        // permission is unexpectedly denied we skip it.
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fetchExactLyrics(for query: LyricsTrackQuery, trackKey: String) async throws -> TrackLyrics? {
        guard let url = makeURL(
            endpoint: "get",
            queryItems: queryItems(for: query, includeAlbum: true, includeDuration: true)
        ) else {
            return nil
        }

        let data = try await data(from: url, allowsNotFound: true)
        guard let data else { return nil }

        let response = try decoder.decode(Response.self, from: data)
        return makeTrackLyrics(from: response, trackKey: trackKey)
    }

    private func searchLyrics(for query: LyricsTrackQuery, trackKey: String) async throws -> TrackLyrics? {
        // Three progressively-broader search attempts: title+artist+duration,
        // then title+artist, then a free-text "q" query. Mirrors
        // DynamicNotch's order so match quality is comparable.
        let searchAttempts = [
            queryItems(for: query, includeAlbum: false, includeDuration: true),
            queryItems(for: query, includeAlbum: false, includeDuration: false),
            [
                URLQueryItem(
                    name: "q",
                    value: [query.artist.lyricsTrimmed, query.title.lyricsTrimmed]
                        .filter { $0.isEmpty == false }
                        .joined(separator: " ")
                )
            ]
        ]

        for queryItems in searchAttempts {
            guard let url = makeURL(endpoint: "search", queryItems: queryItems) else {
                continue
            }

            guard let data = try await data(from: url, allowsNotFound: false) else {
                continue
            }

            let responses = try decoder.decode([Response].self, from: data)
            if let lyrics = bestResponse(from: responses, for: query)
                .flatMap({ makeTrackLyrics(from: $0, trackKey: trackKey) }) {
                return lyrics
            }
        }

        return nil
    }

    private func makeURL(endpoint: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url
    }

    private func queryItems(for query: LyricsTrackQuery, includeAlbum: Bool, includeDuration: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "track_name", value: query.title.lyricsTrimmed),
            URLQueryItem(name: "artist_name", value: query.artist.lyricsTrimmed)
        ]

        if includeAlbum, query.album.lyricsTrimmed.isEmpty == false {
            items.append(URLQueryItem(name: "album_name", value: query.album.lyricsTrimmed))
        }

        if includeDuration, query.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(query.duration.rounded()))"))
        }

        return items
    }

    private func data(from url: URL, allowsNotFound: Bool) async throws -> Data? {
        var request = URLRequest(url: url)
        // LRCLIB asks API consumers to identify themselves so they can
        // contact us about bad behavior. Identifying as NotchApp keeps the
        // attribution clean (DynamicNotch sent their own UA).
        request.setValue(
            "NotchApp/1.0 (https://github.com/erwinzhang/NotchApp)",
            forHTTPHeaderField: "User-Agent"
        )
        NSLog("[Lyrics] HTTP -> %@", url.absoluteString)
        let start = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            NSLog("[Lyrics] HTTP <- ERROR after %.2fs url=%@ err=%@",
                  Date().timeIntervalSince(start), url.absoluteString, String(describing: error))
            throw error
        }

        let dt = Date().timeIntervalSince(start)
        guard let httpResponse = response as? HTTPURLResponse else {
            NSLog("[Lyrics] HTTP <- non-HTTP response after %.2fs url=%@", dt, url.absoluteString)
            throw URLError(.badServerResponse)
        }
        NSLog("[Lyrics] HTTP <- %d in %.2fs (%d bytes) url=%@",
              httpResponse.statusCode, dt, data.count, url.absoluteString)

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 404 where allowsNotFound:
            return nil
        default:
            throw URLError(.badServerResponse)
        }
    }

    private func bestResponse(from responses: [Response], for query: LyricsTrackQuery) -> Response? {
        responses
            .filter { response in
                response.instrumental == true ||
                response.syncedLyrics?.lyricsTrimmed.isEmpty == false ||
                response.plainLyrics?.lyricsTrimmed.isEmpty == false
            }
            .max { first, second in
                matchScore(first, query: query) < matchScore(second, query: query)
            }
    }

    private func matchScore(_ response: Response, query: LyricsTrackQuery) -> Int {
        let title = query.title.lyricsNormalized
        let artist = query.artist.lyricsNormalized
        let album = query.album.lyricsNormalized
        let responseTitle = response.trackName?.lyricsNormalized ?? ""
        let responseArtist = response.artistName?.lyricsNormalized ?? ""
        let responseAlbum = response.albumName?.lyricsNormalized ?? ""
        let durationDelta = response.duration.map {
            abs(Int($0.rounded()) - Int(query.duration.rounded()))
        }

        var score = 0
        if responseTitle == title { score += 120 }
        if responseArtist == artist { score += 90 }
        if album.isEmpty == false, responseAlbum == album { score += 35 }
        if response.syncedLyrics?.lyricsTrimmed.isEmpty == false { score += 20 }
        if let durationDelta {
            if durationDelta <= 2 { score += 24 }
            else if durationDelta <= 6 { score += 12 }
        }

        return score
    }

    private func makeTrackLyrics(from response: Response, trackKey: String) -> TrackLyrics? {
        if response.instrumental == true {
            return TrackLyrics(
                trackKey: trackKey,
                lines: [LyricLine(id: 0, startTime: nil, text: "Instrumental")],
                isSynced: false
            )
        }

        let syncedLines = Self.parseSyncedLyrics(response.syncedLyrics)
        if syncedLines.isEmpty == false {
            return TrackLyrics(trackKey: trackKey, lines: syncedLines, isSynced: true)
        }

        let plainLines = Self.parsePlainLyrics(response.plainLyrics)
        if plainLines.isEmpty == false {
            return TrackLyrics(trackKey: trackKey, lines: plainLines, isSynced: false)
        }

        return nil
    }

    private static func parsePlainLyrics(_ lyrics: String?) -> [LyricLine] {
        lyrics?
            .components(separatedBy: .newlines)
            .map(\.lyricsTrimmed)
            .filter { $0.isEmpty == false }
            .enumerated()
            .map { index, text in
                LyricLine(id: index, startTime: nil, text: text)
            } ?? []
    }

    private static func parseSyncedLyrics(_ lyrics: String?) -> [LyricLine] {
        guard let lyrics, lyrics.lyricsTrimmed.isEmpty == false else { return [] }

        // LRC timestamps look like `[mm:ss]` or `[mm:ss.fff]`; a single
        // line can carry multiple anchors (chorus repeats).
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        var parsedLines: [(startTime: TimeInterval, text: String)] = []

        for rawLine in lyrics.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = expression.matches(in: rawLine, range: fullRange)
            guard let lastMatch = matches.last else { continue }

            let textStart = lastMatch.range.location + lastMatch.range.length
            let text = nsLine.substring(from: min(textStart, nsLine.length)).lyricsTrimmed
            guard text.isEmpty == false else { continue }

            for match in matches {
                guard let startTime = startTime(from: match, line: nsLine) else { continue }
                parsedLines.append((startTime: startTime, text: text))
            }
        }

        return parsedLines
            .sorted { $0.startTime < $1.startTime }
            .enumerated()
            .map { index, line in
                LyricLine(id: index, startTime: line.startTime, text: line.text)
            }
    }

    private static func startTime(from match: NSTextCheckingResult, line: NSString) -> TimeInterval? {
        guard
            let minutes = integerValue(in: match.range(at: 1), line: line),
            let seconds = integerValue(in: match.range(at: 2), line: line)
        else {
            return nil
        }

        let fraction = fractionalSeconds(in: match.range(at: 3), line: line)
        return TimeInterval((minutes * 60) + seconds) + fraction
    }

    private static func integerValue(in range: NSRange, line: NSString) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int(line.substring(with: range))
    }

    private static func fractionalSeconds(in range: NSRange, line: NSString) -> TimeInterval {
        guard range.location != NSNotFound else { return 0 }

        let rawValue = line.substring(with: range)
        guard let value = Double(rawValue) else { return 0 }

        // LRC fractional component can be 1–3 digits (tenths, hundredths,
        // thousandths). Scale accordingly so `[01:00.5]` is 60.5s, not 60.005s.
        switch rawValue.count {
        case 1:
            return value / 10
        case 2:
            return value / 100
        default:
            return value / 1000
        }
    }
}
