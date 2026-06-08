import Combine
import Foundation

@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()

    @Published private(set) var snapshot = TokenUsageSnapshot()

    private let claudeReader = ClaudeUsageReader()
    private let codexReader = CodexUsageReader()
    private let pricingCache = TokenPricingCache()
    private var refreshTask: Task<Void, Never>?
    private var intakeTimer: Timer?
    private var pricingTimer: Timer?

    private init() {}

    func start() {
        schedulePricingRefresh()
        // Load events immediately using whatever pricing is already cached —
        // do NOT block the first load behind the network pricing fetch.
        // (Gating the load on `refreshIfNeeded` meant a slow/stalled pricing
        // request delayed all token data until the 300 s timer.)
        Task { await refresh() }
        // Refresh pricing in the background, then re-run once so costs pick
        // up any newly-published model rates.
        Task {
            await pricingCache.refreshIfNeeded()
            await refresh()
        }

        intakeTimer?.invalidate()
        intakeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        intakeTimer?.invalidate()
        intakeTimer = nil
        pricingTimer?.invalidate()
        pricingTimer = nil
    }

    func refresh() async {
        refreshTask?.cancel()
        let pricingCache = self.pricingCache
        refreshTask = Task {
            let rawResult = await Task.detached(priority: .utility) { [claudeReader, codexReader] in
                var claude = claudeReader.loadEvents()
                let codex = codexReader.loadEvents()
                claude.events.append(contentsOf: codex.events)
                claude.filesScanned += codex.filesScanned
                claude.warnings.append(contentsOf: codex.warnings)
                return claude
            }.value

            var events: [TokenUsageEvent] = []
            events.reserveCapacity(rawResult.events.count)
            for var event in rawResult.events.sorted(by: { $0.timestamp < $1.timestamp }) {
                event.estimatedCostUSD = await pricingCache.estimatedCost(for: event)
                events.append(event)
            }

            guard !Task.isCancelled else { return }
            snapshot = makeSnapshot(from: events, filesScanned: rawResult.filesScanned, warnings: rawResult.warnings)
            NSLog("[TokenUsage] Loaded \(snapshot.eventsLoaded) event(s) from \(snapshot.filesScanned) file(s); estimated cost $\(String(format: "%.2f", snapshot.totals.estimatedCostUSD))")
        }
    }

    private func schedulePricingRefresh() {
        pricingTimer?.invalidate()

        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0
        components.second = 0

        var fireDate = Calendar.current.date(from: components) ?? now.addingTimeInterval(3600)
        if fireDate <= now {
            fireDate = Calendar.current.date(byAdding: .day, value: 1, to: fireDate) ?? now.addingTimeInterval(86400)
        }

        pricingTimer = Timer(fireAt: fireDate, interval: 86400, target: self, selector: #selector(refreshPricingTimerFired), userInfo: nil, repeats: true)
        if let pricingTimer {
            RunLoop.main.add(pricingTimer, forMode: .common)
        }
    }

    @objc private func refreshPricingTimerFired() {
        Task {
            await pricingCache.refresh()
            await refresh()
        }
    }

    private func makeSnapshot(
        from events: [TokenUsageEvent],
        filesScanned: Int,
        warnings: [String]
    ) -> TokenUsageSnapshot {
        var snapshot = TokenUsageSnapshot()
        snapshot.generatedAt = Date()
        snapshot.filesScanned = filesScanned
        snapshot.eventsLoaded = events.count
        snapshot.warnings = warnings

        for event in events {
            snapshot.totals.add(event)

            var sourceTotals = snapshot.bySource[event.source] ?? TokenUsageTotals()
            sourceTotals.add(event)
            snapshot.bySource[event.source] = sourceTotals

            let day = TokenUsageJSONL.dayFormatter.string(from: event.timestamp)
            var dayTotals = snapshot.byDay[day] ?? TokenUsageTotals()
            dayTotals.add(event)
            snapshot.byDay[day] = dayTotals

            let modelKey = "\(event.source.rawValue):\(event.model)"
            var modelTotals = snapshot.byModel[modelKey] ?? TokenUsageTotals()
            modelTotals.add(event)
            snapshot.byModel[modelKey] = modelTotals

            var periodTotals = snapshot.periodTotals[event.source] ?? TokenUsagePeriodTotals()
            let now = Date()
            if Calendar.current.isDateInToday(event.timestamp) {
                periodTotals.daily.add(event)
            }
            if Calendar.current.isDate(event.timestamp, equalTo: now, toGranularity: .weekOfYear) {
                periodTotals.weekly.add(event)
            }
            if Calendar.current.isDate(event.timestamp, equalTo: now, toGranularity: .month) {
                periodTotals.monthly.add(event)
            }
            snapshot.periodTotals[event.source] = periodTotals
        }

        return snapshot
    }
}
