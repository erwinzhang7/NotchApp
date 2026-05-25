import AppKit
import SwiftUI

/// Empty-state placeholder for the Clip tab. Replaces the noisy
/// ContentUnavailableView with a single Claude-style time-of-day
/// greeting that uses the system account's first name. When the user is
/// searching with no results, falls back to a quiet "No matches" line.
struct EmptyClipStateView: View {
    let searchQuery: String

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            Text(message(for: ctx.date))
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(for date: Date) -> String {
        if !searchQuery.isEmpty { return "No matches" }
        let name = Self.firstName
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<12:  return "Good morning, \(name)."
        case 12..<18: return "Good afternoon, \(name)."
        case 18..<23: return "Good evening, \(name)."
        default:      return "Late night session, \(name)?"
        }
    }

    /// macOS account full name → first whitespace-separated token. Falls
    /// back to the short username, then "there", so the greeting never
    /// looks broken on stripped-down accounts.
    private static let firstName: String = {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if let first = full.split(whereSeparator: { $0.isWhitespace }).first,
           !first.isEmpty {
            return String(first)
        }
        let short = NSUserName().trimmingCharacters(in: .whitespaces)
        if !short.isEmpty { return short.capitalized }
        return "there"
    }()
}
