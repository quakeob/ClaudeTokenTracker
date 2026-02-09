import Cocoa
import SwiftUI
import UserNotifications

// MARK: - Data Models

struct ModelUsage: Codable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadInputTokens: Int64
    let cacheCreationInputTokens: Int64
    let webSearchRequests: Int64?
    let costUSD: Double?
    let contextWindow: Int64?
    let maxOutputTokens: Int64?

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }

    var totalInput: Int64 {
        inputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }
}

struct DailyActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int64]
}

struct LongestSession: Codable {
    let sessionId: String
    let duration: Int64
    let messageCount: Int
    let timestamp: String
}

struct StatsCache: Codable {
    let version: Int?
    let lastComputedDate: String?
    let dailyActivity: [DailyActivity]?
    let dailyModelTokens: [DailyModelTokens]?
    let modelUsage: [String: ModelUsage]?
    let totalSessions: Int?
    let totalMessages: Int?
    let longestSession: LongestSession?
    let firstSessionDate: String?
    let hourCounts: [String: Int]?
    let totalSpeculationTimeSavedMs: Int64?
}

// MARK: - JSONL File State (incremental parsing cache)

struct JSONLFileState {
    var offset: UInt64
    var modelTokens: [String: [Int64]]  // model -> [input, output, cacheRead, cacheCreate]
}

// MARK: - App Settings

struct AppSettings: Codable {
    // General
    var alwaysOnTop: Bool = true
    var showOnAllSpaces: Bool = true
    var startMinimized: Bool = false

    // Appearance
    var widgetOpacity: Double = 1.0
    var showCostEstimate: Bool = true
    var showModelBreakdown: Bool = true
    var showSessionStats: Bool = true

    // Budget & Alerts
    var dailyBudget: Int64 = 0
    var budgetWarningThreshold: Double = 0.8
    var notificationsEnabled: Bool = true
    var budgetWarning80Fired: Bool = false
    var budgetWarning100Fired: Bool = false
    var firedMilestones: [Int64] = []

    // Data
    var refreshInterval: Double = 10.0

    // Persisted state
    var windowX: Double?
    var windowY: Double?
    var dayStartTokens: Int64 = 0
    var dayStartDate: String = ""

    static let fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude-token-tracker.json")
    }()

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL)
    }
}

// MARK: - Notification Manager

enum NotificationManager {
    static let milestones: [Int64] = [
        100_000, 500_000, 1_000_000, 5_000_000,
        10_000_000, 25_000_000, 50_000_000, 100_000_000
    ]

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func checkMilestones(totalTokens: Int64, settings: inout AppSettings) {
        guard settings.notificationsEnabled else { return }
        for milestone in milestones {
            if totalTokens >= milestone && !settings.firedMilestones.contains(milestone) {
                settings.firedMilestones.append(milestone)
                send(
                    title: "Token Milestone!",
                    body: "You've hit \(formatCompact(milestone)) lifetime Claude tokens."
                )
                settings.save()
            }
        }
    }

    static func checkBudget(todayTokens: Int64, budget: Int64, settings: inout AppSettings) {
        guard settings.notificationsEnabled, budget > 0 else { return }
        let fraction = Double(todayTokens) / Double(budget)
        let threshold = settings.budgetWarningThreshold

        if fraction >= 1.0 && !settings.budgetWarning100Fired {
            settings.budgetWarning100Fired = true
            send(
                title: "Budget Exceeded",
                body: "You've exceeded today's token budget (\(formatCompact(todayTokens)) / \(formatCompact(budget)))."
            )
            settings.save()
        } else if fraction >= threshold && !settings.budgetWarning80Fired {
            settings.budgetWarning80Fired = true
            let pct = Int(threshold * 100)
            send(
                title: "Budget Warning",
                body: "You've used \(pct)% of today's token budget (\(formatCompact(todayTokens)) / \(formatCompact(budget)))."
            )
            settings.save()
        }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Token Store

class TokenStore: ObservableObject {
    @Published var stats: StatsCache?
    @Published var lastUpdated: Date = Date()
    @Published var isMinimized: Bool = false
    @Published var settings: AppSettings

    var onSizeChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSettingsChanged: (() -> Void)?

    private let statsURL: URL
    private var timer: Timer?
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private let scanQueue = DispatchQueue(label: "com.jakedavis.token-tracker.scan")
    private var fileStates: [String: JSONLFileState] = [:]
    private var jsonlWatcherSources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: Set<String> = []
    @Published var liveModelUsage: [String: ModelUsage]?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        statsURL = home.appendingPathComponent(".claude/stats-cache.json")
        settings = AppSettings.load()
        if settings.startMinimized { isMinimized = true }
        reload()
        scanJSONLFiles()
        checkDayRollover()
        startAutoRefresh()
        startFileWatcher()
    }

    func reload() {
        guard let data = try? Data(contentsOf: statsURL),
              let decoded = try? JSONDecoder().decode(StatsCache.self, from: data) else {
            return
        }
        DispatchQueue.main.async {
            self.stats = decoded
            self.lastUpdated = Date()
            self.checkDayRollover()
            NotificationManager.checkMilestones(totalTokens: self.totalTokens, settings: &self.settings)
            NotificationManager.checkBudget(todayTokens: self.todayTokens, budget: self.settings.dailyBudget, settings: &self.settings)
        }
    }

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.reload()
            self?.scanJSONLFiles()
        }
    }

    func startFileWatcher() {
        let fd = open(statsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcherSource = source
    }

    // MARK: Live JSONL Scanning

    func scanJSONLFiles() {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let projectsDir = home.appendingPathComponent(".claude/projects")
            guard fm.fileExists(atPath: projectsDir.path) else { return }

            guard let enumerator = fm.enumerator(
                at: projectsDir,
                includingPropertiesForKeys: nil,
                options: []
            ) else { return }

            var allUsage: [String: [Int64]] = [:]

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                let path = fileURL.path
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                if let state = self.fileStates[path], state.offset >= fileSize {
                    for (model, counts) in state.modelTokens {
                        var e = allUsage[model] ?? [0, 0, 0, 0]
                        for i in 0..<4 { e[i] += counts[i] }
                        allUsage[model] = e
                    }
                    continue
                }

                let existing = self.fileStates[path]
                let startOffset = existing?.offset ?? 0
                var fileCounts = existing?.modelTokens ?? [:]

                guard let fh = FileHandle(forReadingAtPath: path) else { continue }
                defer { fh.closeFile() }

                fh.seek(toFileOffset: startOffset)
                let newData = fh.readDataToEndOfFile()
                guard !newData.isEmpty,
                      let text = String(data: newData, encoding: .utf8) else { continue }

                var bytesConsumed: Int = 0
                let lines = text.components(separatedBy: "\n")

                for (i, line) in lines.enumerated() {
                    // Always skip the last element: it's either empty (after trailing \n) or an incomplete line
                    if i == lines.count - 1 { break }
                    bytesConsumed += line.utf8.count + 1  // +1 for \n separator
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }

                    guard let ld = trimmed.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                          (obj["type"] as? String) == "assistant",
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any],
                          let model = msg["model"] as? String,
                          !model.isEmpty else { continue }

                    let inp = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let out = (usage["output_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cr = (usage["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
                    let cc = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0

                    var mc = fileCounts[model] ?? [0, 0, 0, 0]
                    mc[0] += inp; mc[1] += out; mc[2] += cr; mc[3] += cc
                    fileCounts[model] = mc
                }

                self.fileStates[path] = JSONLFileState(
                    offset: startOffset + UInt64(bytesConsumed),
                    modelTokens: fileCounts
                )

                for (model, counts) in fileCounts {
                    var e = allUsage[model] ?? [0, 0, 0, 0]
                    for i in 0..<4 { e[i] += counts[i] }
                    allUsage[model] = e
                }
            }

            var result: [String: ModelUsage] = [:]
            for (model, c) in allUsage {
                result[model] = ModelUsage(
                    inputTokens: c[0],
                    outputTokens: c[1],
                    cacheReadInputTokens: c[2],
                    cacheCreationInputTokens: c[3],
                    webSearchRequests: 0,
                    costUSD: nil,
                    contextWindow: nil,
                    maxOutputTokens: nil
                )
            }

            let knownPaths = Array(self.fileStates.keys)

            DispatchQueue.main.async {
                self.liveModelUsage = result
                self.lastUpdated = Date()
                self.watchJSONLFiles(paths: knownPaths)
                NotificationManager.checkMilestones(
                    totalTokens: self.totalTokens, settings: &self.settings
                )
                NotificationManager.checkBudget(
                    todayTokens: self.todayTokens,
                    budget: self.settings.dailyBudget,
                    settings: &self.settings
                )
            }
        }
    }

    private func watchJSONLFiles(paths: [String]) {
        for path in paths {
            guard !watchedPaths.contains(path) else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.scanJSONLFiles()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            jsonlWatcherSources.append(source)
            watchedPaths.insert(path)
        }
    }

    func toggleMinimized() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isMinimized.toggle()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.onSizeChange?()
        }
    }

    // MARK: Day tracking

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func checkDayRollover() {
        let today = Self.todayString()
        if settings.dayStartDate != today {
            settings.dayStartDate = today
            settings.dayStartTokens = totalTokens
            settings.budgetWarning80Fired = false
            settings.budgetWarning100Fired = false
            settings.save()
        }
    }

    var todayTokens: Int64 {
        max(0, totalTokens - settings.dayStartTokens)
    }

    var budgetFraction: Double {
        guard settings.dailyBudget > 0 else { return 0 }
        return Double(todayTokens) / Double(settings.dailyBudget)
    }

    // MARK: Reset & Export

    func resetToday() {
        settings.dayStartTokens = totalTokens
        settings.dayStartDate = Self.todayString()
        settings.budgetWarning80Fired = false
        settings.budgetWarning100Fired = false
        settings.save()
        objectWillChange.send()
    }

    func resetAll() {
        settings = AppSettings()
        settings.dayStartDate = Self.todayString()
        settings.dayStartTokens = totalTokens
        settings.save()
        objectWillChange.send()
    }

    func exportCSV() {
        guard let activity = stats?.dailyActivity else { return }
        var csv = "Date,Messages,Sessions,Tool Calls\n"
        for day in activity {
            csv += "\(day.date),\(day.messageCount),\(day.sessionCount),\(day.toolCallCount)\n"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop/claude-token-usage.csv")
        try? csv.write(to: desktop, atomically: true, encoding: .utf8)
        NSWorkspace.shared.selectFile(desktop.path, inFileViewerRootedAtPath: "")
    }

    // MARK: Computed stats

    private var effectiveModelUsage: [String: ModelUsage]? {
        if let live = liveModelUsage, !live.isEmpty { return live }
        return stats?.modelUsage
    }

    var totalTokens: Int64 {
        effectiveModelUsage?.values.reduce(0) { $0 + $1.totalTokens } ?? 0
    }

    var totalInput: Int64 {
        effectiveModelUsage?.values.reduce(0) { $0 + $1.totalInput } ?? 0
    }

    var totalOutput: Int64 {
        effectiveModelUsage?.values.reduce(0) { $0 + $1.outputTokens } ?? 0
    }

    var estimatedCost: Double {
        guard let usage = effectiveModelUsage else { return 0 }
        var cost = 0.0
        for (model, u) in usage {
            cost += Self.estimateModelCost(model: model, usage: u)
        }
        return cost
    }

    static func estimateModelCost(model: String, usage: ModelUsage) -> Double {
        let m = model.lowercased()
        if m.contains("opus") {
            return Double(usage.inputTokens) / 1e6 * 15
                 + Double(usage.outputTokens) / 1e6 * 75
                 + Double(usage.cacheReadInputTokens) / 1e6 * 1.875
                 + Double(usage.cacheCreationInputTokens) / 1e6 * 18.75
        } else if m.contains("sonnet") {
            return Double(usage.inputTokens) / 1e6 * 3
                 + Double(usage.outputTokens) / 1e6 * 15
                 + Double(usage.cacheReadInputTokens) / 1e6 * 0.375
                 + Double(usage.cacheCreationInputTokens) / 1e6 * 3.75
        } else if m.contains("haiku") {
            return Double(usage.inputTokens) / 1e6 * 0.25
                 + Double(usage.outputTokens) / 1e6 * 1.25
                 + Double(usage.cacheReadInputTokens) / 1e6 * 0.03125
                 + Double(usage.cacheCreationInputTokens) / 1e6 * 0.3125
        }
        return Double(usage.totalTokens) / 1e6 * 10
    }

    var modelBreakdown: [(name: String, tokens: Int64, color: Color)] {
        guard let usage = effectiveModelUsage else { return [] }
        return usage.sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { (name: Self.formatModelName($0.key),
                     tokens: $0.value.totalTokens,
                     color: Self.modelColor($0.key)) }
    }

    static func formatModelName(_ raw: String) -> String {
        if raw.contains("opus-4-6") { return "Opus 4.6" }
        if raw.contains("opus-4-5") { return "Opus 4.5" }
        if raw.contains("sonnet-4-5") { return "Sonnet 4.5" }
        if raw.contains("sonnet-4") { return "Sonnet 4" }
        if raw.contains("haiku") { return "Haiku" }
        return raw
    }

    static func modelColor(_ raw: String) -> Color {
        if raw.contains("opus-4-6") { return .orange }
        if raw.contains("opus-4-5") { return .pink }
        if raw.contains("sonnet") { return .blue }
        if raw.contains("haiku") { return .green }
        return .gray
    }

    var firstSessionFormatted: String {
        guard let dateStr = stats?.firstSessionDate else { return "\u{2014}" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) else { return "\u{2014}" }
        let display = DateFormatter()
        display.dateFormat = "MMM d, yyyy"
        return display.string(from: date)
    }

    // MARK: Launch at login

    var isLaunchAtLoginEnabled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.jakedavis.claude-token-tracker.plist")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentDir = home.appendingPathComponent("Library/LaunchAgents")
        let plistURL = agentDir.appendingPathComponent("com.jakedavis.claude-token-tracker.plist")

        if enabled {
            try? FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
            let appPath = Bundle.main.executablePath ?? ""
            let dict: NSDictionary = [
                "Label": "com.jakedavis.claude-token-tracker",
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            dict.write(to: plistURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - Formatters

func formatTokenCount(_ count: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
}

func formatCompact(_ count: Int64) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var store: TokenStore

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            heroSection
            if !store.isMinimized {
                todaySection
                cardsSection
                if store.settings.showModelBreakdown {
                    modelSection
                }
                divider
                footerSection
            }
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(glassHighlight)
        .overlay(glassBorder)
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .opacity(store.settings.widgetOpacity)
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text("CLAUDE TOKENS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button(action: { store.onOpenSettings?() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            Button(action: { store.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            Button(action: { store.toggleMinimized() }) {
                Image(systemName: store.isMinimized ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: Hero Number

    private var heroSection: some View {
        VStack(spacing: 4) {
            Text(formatTokenCount(store.totalTokens))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.6), value: store.totalTokens)

            Text("lifetime tokens")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.bottom, 14)
    }

    // MARK: Today / Budget

    private var todaySection: some View {
        Group {
            if store.settings.dailyBudget > 0 {
                BudgetBar(
                    current: store.todayTokens,
                    budget: store.settings.dailyBudget
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            } else {
                HStack {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Text(formatCompact(store.todayTokens))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: Input/Output Cards

    private var cardsSection: some View {
        HStack(spacing: 8) {
            StatCard(
                title: "Input",
                value: formatCompact(store.totalInput),
                icon: "arrow.down.circle.fill",
                color: .cyan
            )
            StatCard(
                title: "Output",
                value: formatCompact(store.totalOutput),
                icon: "arrow.up.circle.fill",
                color: .purple
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Model Breakdown

    private var modelSection: some View {
        VStack(spacing: 5) {
            ForEach(store.modelBreakdown, id: \.name) { model in
                ModelRow(
                    name: model.name,
                    tokens: model.tokens,
                    maxTokens: store.totalTokens,
                    color: model.color
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    // MARK: Divider

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    // MARK: Footer

    private var footerSection: some View {
        VStack(spacing: 6) {
            if store.settings.showCostEstimate {
                HStack {
                    Text("API Equivalent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Text(String(format: "~$%.2f", store.estimatedCost))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if store.settings.showSessionStats {
                HStack {
                    Label("\(store.stats?.totalMessages ?? 0) msgs", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    Label("\(store.stats?.totalSessions ?? 0) sessions", systemImage: "terminal")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))

                HStack {
                    Text("Since \(store.firstSessionFormatted)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.18))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    // MARK: Glass Overlays

    private var glassHighlight: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.12), location: 0),
                .init(color: .white.opacity(0.03), location: 0.3),
                .init(color: .clear, location: 0.5),
                .init(color: .white.opacity(0.02), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .allowsHitTesting(false)
    }

    private var glassBorder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.2), .white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
    }
}

// MARK: - Budget Bar

struct BudgetBar: View {
    let current: Int64
    let budget: Int64

    private var fraction: Double {
        guard budget > 0 else { return 0 }
        return Double(current) / Double(budget)
    }

    private var barFill: Double {
        min(fraction, 1.0)
    }

    private var barColor: Color {
        if fraction >= 1.0 { return .red }
        if fraction >= 0.8 { return .orange }
        if fraction >= 0.5 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(barColor.opacity(0.6))
                        .frame(width: max(0, geo.size.width * barFill))
                        .animation(.spring(duration: 0.5), value: barFill)
                }
            }
            .frame(height: 5)

            HStack {
                Text("\(formatCompact(current)) / \(formatCompact(budget))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(fraction >= 1.0 ? "over budget" : "today")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(fraction >= 1.0 ? Color.red.opacity(0.7) : .white.opacity(0.25))
            }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.7))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let name: String
    let tokens: Int64
    let maxTokens: Int64
    let color: Color

    private var fraction: CGFloat {
        guard maxTokens > 0 else { return 0 }
        return CGFloat(tokens) / CGFloat(maxTokens)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 66, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.45))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)

            Text(formatCompact(tokens))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var store: TokenStore
    var onClose: () -> Void

    // General
    @State private var launchAtLogin: Bool = false
    @State private var alwaysOnTop: Bool = true
    @State private var showOnAllSpaces: Bool = true
    @State private var startMinimized: Bool = false

    // Appearance
    @State private var widgetOpacity: Double = 1.0
    @State private var showCostEstimate: Bool = true
    @State private var showModelBreakdown: Bool = true
    @State private var showSessionStats: Bool = true

    // Budget
    @State private var budgetText: String = ""
    @State private var warningThreshold: Double = 0.8
    @State private var notificationsEnabled: Bool = true

    // Data
    @State private var refreshInterval: Double = 5.0
    @State private var showResetConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("SETTINGS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    generalSection
                    appearanceSection
                    budgetSection
                    dataSection
                    footerButtons
                    aboutSection
                }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: 520)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { loadValues() }
    }

    // MARK: Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.25))
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: Toggle Row

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 3)
    }

    // MARK: General

    private var generalSection: some View {
        VStack(spacing: 0) {
            sectionHeader("GENERAL")
            toggleRow("Launch at Login", isOn: $launchAtLogin)
            toggleRow("Always on Top", isOn: $alwaysOnTop)
            toggleRow("Show on All Spaces", isOn: $showOnAllSpaces)
            toggleRow("Start Minimized", isOn: $startMinimized)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(spacing: 0) {
            sectionHeader("APPEARANCE")

            VStack(spacing: 4) {
                HStack {
                    Text("Widget Opacity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(widgetOpacity * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Slider(value: $widgetOpacity, in: 0.3...1.0, step: 0.05)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            toggleRow("Show Cost Estimate", isOn: $showCostEstimate)
            toggleRow("Show Model Breakdown", isOn: $showModelBreakdown)
            toggleRow("Show Session Stats", isOn: $showSessionStats)
        }
    }

    // MARK: Budget

    private var budgetSection: some View {
        VStack(spacing: 0) {
            sectionHeader("BUDGET & ALERTS")

            VStack(alignment: .leading, spacing: 6) {
                Text("Daily Token Budget")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                TextField("0", text: $budgetText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 0.5)
                    )

                Text("tokens per day \u{00b7} 0 = no limit")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            VStack(spacing: 4) {
                HStack {
                    Text("Warning Threshold")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(warningThreshold * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Slider(value: $warningThreshold, in: 0.5...0.95, step: 0.05)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            toggleRow("Notifications", isOn: $notificationsEnabled)
        }
    }

    // MARK: Data

    private var dataSection: some View {
        VStack(spacing: 0) {
            sectionHeader("DATA")

            VStack(spacing: 4) {
                HStack {
                    Text("Refresh Interval")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(refreshLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Slider(value: $refreshInterval, in: 2...60, step: 1)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button(action: { store.resetToday() }) {
                    Text("Reset Today")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: { store.exportCSV() }) {
                    Text("Export CSV")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Button(action: { showResetConfirm = true }) {
                Text("Reset All Data")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .alert("Reset All Data?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    store.resetAll()
                    loadValues()
                }
            } message: {
                Text("This will clear all settings, milestones, and saved data. This cannot be undone.")
            }
        }
    }

    // MARK: Footer

    private var footerButtons: some View {
        Button(action: save) {
            Text("Save")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var aboutSection: some View {
        Text("Claude Token Tracker v1.0")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.15))
            .padding(.top, 10)
            .padding(.bottom, 16)
    }

    // MARK: Helpers

    private var refreshLabel: String {
        if refreshInterval < 60 {
            return "\(Int(refreshInterval))s"
        }
        return "60s"
    }

    private func loadValues() {
        let s = store.settings
        launchAtLogin = store.isLaunchAtLoginEnabled
        alwaysOnTop = s.alwaysOnTop
        showOnAllSpaces = s.showOnAllSpaces
        startMinimized = s.startMinimized
        widgetOpacity = s.widgetOpacity
        showCostEstimate = s.showCostEstimate
        showModelBreakdown = s.showModelBreakdown
        showSessionStats = s.showSessionStats
        budgetText = s.dailyBudget > 0 ? "\(s.dailyBudget)" : "0"
        warningThreshold = s.budgetWarningThreshold
        notificationsEnabled = s.notificationsEnabled
        refreshInterval = s.refreshInterval
    }

    private func save() {
        let cleaned = budgetText.replacingOccurrences(of: ",", with: "")
        store.settings.dailyBudget = max(0, Int64(cleaned) ?? 0)
        store.settings.alwaysOnTop = alwaysOnTop
        store.settings.showOnAllSpaces = showOnAllSpaces
        store.settings.startMinimized = startMinimized
        store.settings.widgetOpacity = widgetOpacity
        store.settings.showCostEstimate = showCostEstimate
        store.settings.showModelBreakdown = showModelBreakdown
        store.settings.showSessionStats = showSessionStats
        store.settings.budgetWarningThreshold = warningThreshold
        store.settings.notificationsEnabled = notificationsEnabled
        store.settings.refreshInterval = refreshInterval
        store.settings.save()
        store.setLaunchAtLogin(launchAtLogin)
        store.startAutoRefresh()
        store.objectWillChange.send()
        store.onSettingsChanged?()
        store.onSizeChange?()
        onClose()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    let store = TokenStore()
    var tokenItem: NSMenuItem!
    var costItem: NSMenuItem!
    var todayItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.requestPermission()
        setupWindow()
        setupMenuBar()
        setupMainMenu()
    }

    private func setupWindow() {
        let contentView = ContentView(store: store)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.fittingSize)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hostingView

        // Restore saved position or default to top-right
        if let x = store.settings.windowX, let y = store.settings.windowY {
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let wf = window.frame
            let x = sf.maxX - wf.width - 24
            let y = sf.maxY - wf.height - 24
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)

        store.onSizeChange = { [weak self] in
            self?.resizeWindow()
        }

        store.onOpenSettings = { [weak self] in
            self?.openSettings()
        }

        store.onSettingsChanged = { [weak self] in
            self?.applySettings()
        }

        applySettings()

        // Save position when window moves
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
    }

    private func applySettings() {
        let s = store.settings
        window.level = s.alwaysOnTop ? .floating : .normal
        if s.showOnAllSpaces {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.collectionBehavior = [.fullScreenAuxiliary]
        }
    }

    @objc private func windowDidMove(_ notification: Notification) {
        let origin = window.frame.origin
        store.settings.windowX = origin.x
        store.settings.windowY = origin.y
        store.settings.save()
    }

    private func resizeWindow() {
        guard let hostingView = window.contentView as? NSHostingView<ContentView> else { return }
        let newSize = hostingView.fittingSize
        let oldFrame = window.frame
        let newOrigin = NSPoint(x: oldFrame.origin.x, y: oldFrame.maxY - newSize.height)
        let newFrame = NSRect(origin: newOrigin, size: newSize)
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func openSettings() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(store: store, onClose: { [weak self] in
            self?.settingsWindow?.orderOut(nil)
        })
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.contentView = hostingView

        let mainFrame = window.frame
        let x = mainFrame.origin.x - w.frame.width - 12
        let y = mainFrame.maxY - w.frame.height
        w.setFrameOrigin(NSPoint(x: x, y: y))

        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "sparkle",
                accessibilityDescription: "Claude Tokens"
            )
            button.image?.size = NSSize(width: 14, height: 14)
        }

        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(
            title: "Show/Hide Widget",
            action: #selector(toggleWidget),
            keyEquivalent: "t"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        tokenItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tokenItem.isEnabled = false
        menu.addItem(tokenItem)

        todayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        todayItem.isEnabled = false
        menu.addItem(todayItem)

        costItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        costItem.isEnabled = false
        menu.addItem(costItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettingsMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        store.reload()
        tokenItem.title = "Lifetime: \(formatTokenCount(store.totalTokens)) tokens"
        todayItem.title = "Today: \(formatTokenCount(store.todayTokens)) tokens"
        costItem.title = String(format: "API Equivalent: ~$%.2f", store.estimatedCost)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Claude Token Tracker",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func toggleWidget() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openSettingsMenu() {
        openSettings()
    }

    @objc func refresh() {
        store.reload()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
