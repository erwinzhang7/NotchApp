import Foundation

/// LRCLIB.net client. Ported from DynamicNotch and adapted to NotchApp's
/// `LyricsTrackQuery` (DynamicNotch passes a NowPlayingSnapshot struct;
/// our equivalent is a long-lived ObservableObject so the caller builds
/// the query). Pure ingestion — no UI dependencies.
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
    private var cache: [String: CacheEntry] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    /// Returns lyrics for `query`, or nil if the track is unknown to
    /// LRCLIB. Throws on transport errors. Caches both hits and misses
    /// (so consecutive misses don't re-hit the network).
    func lyrics(for query: LyricsTrackQuery) async throws -> TrackLyrics? {
        guard let trackKey = query.cacheKey else { return nil }

        if let cached = cache[trackKey] {
            return cached.lyrics
        }

        if let exactLyrics = try await fetchExactLyrics(for: query, trackKey: trackKey) {
            cache[trackKey] = .found(exactLyrics)
            return exactLyrics
        }

        let searchedLyrics = try await searchLyrics(for: query, trackKey: trackKey)
        cache[trackKey] = searchedLyrics.map(CacheEntry.found) ?? .missing
        return searchedLyrics
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

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
