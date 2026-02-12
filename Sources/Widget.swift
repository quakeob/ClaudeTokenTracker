import WidgetKit
import SwiftUI

// Real home directory (bypasses sandbox container redirect)
private let realHome: URL = {
    let pw = getpwuid(getuid())!
    return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
}()

// MARK: - Timeline Entry

struct TokenEntry: TimelineEntry {
    let date: Date
    let totalTokens: Int64
    let todayTokens: Int64
    let estimatedCost: Double
    let topModel: String
}

// MARK: - Timeline Provider

struct TokenProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenEntry {
        TokenEntry(
            date: Date(),
            totalTokens: 1_500_000,
            todayTokens: 250_000,
            estimatedCost: 12.50,
            topModel: "claude-opus-4-6"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenEntry>) -> Void) {
        let entry = readEntry()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }

    private func readEntry() -> TokenEntry {
        let fileURL = realHome.appendingPathComponent(".claude-token-tracker-widget.json")
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TokenEntry(date: Date(), totalTokens: 0, todayTokens: 0, estimatedCost: 0, topModel: "Claude")
        }
        return TokenEntry(
            date: Date(),
            totalTokens: (json["totalTokens"] as? NSNumber)?.int64Value ?? 0,
            todayTokens: (json["todayTokens"] as? NSNumber)?.int64Value ?? 0,
            estimatedCost: (json["estimatedCost"] as? Double) ?? 0,
            topModel: (json["topModel"] as? String) ?? "Claude"
        )
    }
}

// MARK: - Formatters

private func widgetFormatCompact(_ count: Int64) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

private func shortModelName(_ model: String) -> String {
    let m = model.lowercased()
    if m.contains("opus") { return "Opus" }
    if m.contains("sonnet") { return "Sonnet" }
    if m.contains("haiku") { return "Haiku" }
    return model
}

// MARK: - Widget Views

struct TokenWidgetView: View {
    var entry: TokenEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.12, green: 0.10, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.purple.opacity(0.8))
                Text("Claude Tokens")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Text(widgetFormatCompact(entry.totalTokens))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)

            Text("lifetime tokens")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            Spacer()

            if entry.estimatedCost > 0 {
                Text("~$\(String(format: "%.2f", entry.estimatedCost))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green.opacity(0.7))
            }
        }
        .padding(2)
    }

    private var mediumView: some View {
        HStack(spacing: 0) {
            // Left: total tokens
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.purple.opacity(0.8))
                    Text("Claude Tokens")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                Text(widgetFormatCompact(entry.totalTokens))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)

                Text("lifetime tokens")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()
            }
            .padding(2)

            Spacer()

            // Right: today + model + cost
            VStack(alignment: .trailing, spacing: 8) {
                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Today")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(widgetFormatCompact(entry.todayTokens))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(shortModelName(entry.topModel))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple.opacity(0.7))
                    if entry.estimatedCost > 0 {
                        Text("~$\(String(format: "%.2f", entry.estimatedCost))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.green.opacity(0.7))
                    }
                }

                Spacer()
            }
            .padding(2)
        }
    }
}

// MARK: - Widget Entry Point

@main
struct TokenTrackerWidget: Widget {
    let kind: String = "TokenTrackerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TokenProvider()) { entry in
            TokenWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Token Tracker")
        .description("Track your Claude Code token usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
