import SwiftUI

struct TokenUsageSummaryRow: View {
    @ObservedObject private var store = TokenUsageStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            usageBlock(source: .claude, title: "Claude")
                .frame(maxWidth: .infinity, alignment: .leading)

            usageBlock(source: .codex, title: "Codex")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(height: 60)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func usageBlock(source: TokenUsageSource, title: String) -> some View {
        let periods = store.snapshot.periodTotals[source] ?? TokenUsagePeriodTotals()

        return HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 42, alignment: .leading)
                .lineLimit(1)

            periodLabel("D", periods.daily.estimatedCostUSD)
            separator
            periodLabel("W", periods.weekly.estimatedCostUSD)
            separator
            periodLabel("M", periods.monthly.estimatedCostUSD)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func periodLabel(_ prefix: String, _ value: Double) -> some View {
        Text("\(prefix) \(formatCost(value))")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .monospacedDigit()
    }

    private var separator: some View {
        Text("|")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.22))
    }

    private func formatCost(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.1fK", value / 1000)
        }
        if value >= 100 {
            return String(format: "$%.0f", value)
        }
        if value >= 10 {
            return String(format: "$%.1f", value)
        }
        return String(format: "$%.2f", value)
    }
}
