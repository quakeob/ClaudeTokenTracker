import Cocoa
import SwiftUI
import UserNotifications
import IOKit

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

struct SyncPayload: Codable {
    let schemaVersion: Int
    let machineId: String
    let machineName: String
    let lastUpdated: String
    let modelUsage: [String: ModelUsage]
    let totalTokens: Int64
    let appVersion: String
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
    var hourlyTokens: [String: Int64]   // "yyyy-MM-dd-HH" -> total tokens
}

// MARK: - OpenClaw Session Data

struct OpenClawSession: Codable {
    let sessionId: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let totalTokens: Int64?
    let contextTokens: Int64?
    let updatedAt: String?
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

    // Sync
    var syncEnabled: Bool = false
    var syncFolderPath: String = ""

    // Graph
    var graphPeriod: String = "daily"  // "hourly", "daily", "weekly", "monthly"

    // Discord
    var discordPresenceEnabled: Bool = false

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

// MARK: - Machine Identity

enum MachineIdentity {
    static var hardwareUUID: String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(service) }
        guard service != 0,
              let uuidRef = IORegistryEntryCreateCFProperty(
                  service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
              ) else {
            return fallbackUUID()
        }
        return (uuidRef.takeRetainedValue() as? String) ?? fallbackUUID()
    }

    static var machineName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func fallbackUUID() -> String {
        let key = "com.jakedavis.claude-token-tracker.machine-id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}

// MARK: - Sync Folder Picker

enum SyncFolderPicker {
    static func chooseFolder(current: String?, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a shared folder for cross-machine sync"
        panel.prompt = "Select Sync Folder"
        if let current = current, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url.path)
            } else {
                completion(nil)
            }
        }
    }
}

// MARK: - Sync Manager

class SyncManager {
    let machineId: String
    let machineName: String

    private var syncFolderURL: URL?
    private var folderWatcherSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastWrittenPayload: Data?
    private let writeQueue = DispatchQueue(label: "com.jakedavis.token-tracker.sync-write")

    var remoteMachines: [SyncPayload] = []
    var onRemoteDataChanged: (() -> Void)?

    init() {
        self.machineId = MachineIdentity.hardwareUUID
        self.machineName = MachineIdentity.machineName
    }

    func configure(folderPath: String?) {
        stopWatching()
        guard let path = folderPath, !path.isEmpty else {
            syncFolderURL = nil
            remoteMachines = []
            return
        }
        syncFolderURL = URL(fileURLWithPath: path)
        startWatching()
        readRemoteMachines()
    }

    func writeLocalData(modelUsage: [String: ModelUsage], totalTokens: Int64) {
        guard let folderURL = syncFolderURL else { return }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let payload = SyncPayload(
                schemaVersion: 1,
                machineId: self.machineId,
                machineName: self.machineName,
                lastUpdated: ISO8601DateFormatter().string(from: Date()),
                modelUsage: modelUsage,
                totalTokens: totalTokens,
                appVersion: "1.0"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            guard let data = try? encoder.encode(payload) else { return }
            if data == self.lastWrittenPayload { return }
            let fileURL = folderURL.appendingPathComponent("\(self.machineId).json")
            try? data.write(to: fileURL, options: .atomic)
            self.lastWrittenPayload = data
        }
        debounceWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + 30, execute: workItem)
    }

    func readRemoteMachines() {
        guard let folderURL = syncFolderURL else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var remotes: [SyncPayload] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(SyncPayload.self, from: data) else {
                continue
            }
            if payload.machineId == self.machineId { continue }
            remotes.append(payload)
        }
        self.remoteMachines = remotes
        DispatchQueue.main.async { self.onRemoteDataChanged?() }
    }

    private func startWatching() {
        guard let folderURL = syncFolderURL else { return }
        let fd = open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.readRemoteMachines() }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatcherSource = source
    }

    private func stopWatching() {
        folderWatcherSource?.cancel()
        folderWatcherSource = nil
    }

    var combinedRemoteUsage: [String: ModelUsage] {
        var combined: [String: [Int64]] = [:]
        for remote in remoteMachines {
            for (model, usage) in remote.modelUsage {
                var c = combined[model] ?? [0, 0, 0, 0]
                c[0] += usage.inputTokens
                c[1] += usage.outputTokens
                c[2] += usage.cacheReadInputTokens
                c[3] += usage.cacheCreationInputTokens
                combined[model] = c
            }
        }
        var result: [String: ModelUsage] = [:]
        for (model, c) in combined {
            result[model] = ModelUsage(
                inputTokens: c[0], outputTokens: c[1],
                cacheReadInputTokens: c[2], cacheCreationInputTokens: c[3],
                webSearchRequests: 0, costUSD: nil, contextWindow: nil, maxOutputTokens: nil
            )
        }
        return result
    }
}

// MARK: - Discord Rich Presence

class DiscordRPC {
    private static let clientId = "1471243711622156338"
    private var fd: Int32 = -1
    private var connected = false
    private var enabled = false
    private let queue = DispatchQueue(label: "com.jakedavis.token-tracker.discord")
    private var reconnectWork: DispatchWorkItem?
    private let launchTime = Int(Date().timeIntervalSince1970)

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { queue.async { self.connect() } }
        else { queue.async { self.disconnect() } }
    }

    private func connect() {
        guard fd < 0 else { return }
        let tmp = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        var candidates: [String] = []
        for i in 0...9 { candidates.append("\(tmp)/discord-ipc-\(i)") }
        if !tmp.hasPrefix("/tmp") {
            for i in 0...9 { candidates.append("/tmp/discord-ipc-\(i)") }
        }
        for path in candidates {
            if trySocket(path) {
                sendFrame(op: 0, json: "{\"v\":1,\"client_id\":\"\(Self.clientId)\"}")
                startReadLoop()
                return
            }
        }
        scheduleReconnect()
    }

    private func trySocket(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(s); return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { strcpy(ptr, $0) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } >= 0
        guard ok else { close(s); return false }
        fd = s
        connected = true
        return true
    }

    private func sendFrame(op: UInt32, json: String) {
        guard fd >= 0, let payload = json.data(using: .utf8) else { return }
        var buf = Data(capacity: 8 + payload.count)
        var opLE = op.littleEndian
        buf.append(Data(bytes: &opLE, count: 4))
        var lenLE = UInt32(payload.count).littleEndian
        buf.append(Data(bytes: &lenLE, count: 4))
        buf.append(payload)
        buf.withUnsafeBytes { _ = write(fd, $0.baseAddress!, buf.count) }
    }

    func updateActivity(details: String, state: String) {
        guard enabled, connected else { return }
        queue.async { [self] in
            let pid = ProcessInfo.processInfo.processIdentifier
            let nonce = UUID().uuidString
            let json = """
            {"cmd":"SET_ACTIVITY","args":{"pid":\(pid),"activity":{"details":"\(details)","state":"\(state)","timestamps":{"start":\(launchTime)},"assets":{"large_image":"icon","large_text":"Claude Token Tracker"}}},"nonce":"\(nonce)"}
            """
            sendFrame(op: 1, json: json)
        }
    }

    private func startReadLoop() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            var hdr = [UInt8](repeating: 0, count: 8)
            while let self = self, self.connected, self.fd >= 0 {
                let n = read(self.fd, &hdr, 8)
                guard n == 8 else {
                    self.queue.async { self.handleDisconnect() }
                    return
                }
                let op = hdr.withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
                let len = hdr.withUnsafeBytes { UInt32(littleEndian: $0.load(fromByteOffset: 4, as: UInt32.self)) }
                if len > 0 && len < 65536 {
                    var body = [UInt8](repeating: 0, count: Int(len))
                    let bn = read(self.fd, &body, Int(len))
                    guard bn > 0 else {
                        self.queue.async { self.handleDisconnect() }
                        return
                    }
                }
                if op == 3 { self.queue.async { self.sendFrame(op: 4, json: "{}") } }
                if op == 2 { self.queue.async { self.handleDisconnect() }; return }
            }
        }
    }

    private func handleDisconnect() {
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
        if enabled { scheduleReconnect() }
    }

    private func disconnect() {
        reconnectWork?.cancel()
        connected = false
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.enabled, !self.connected else { return }
            self.connect()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
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
    private let syncManager = SyncManager()
    private let discordRPC = DiscordRPC()
    @Published var remoteMachines: [SyncPayload] = []
    @Published var dailyTokenHistory: [(date: String, tokens: Int64)] = []
    private var rawHourlyTokens: [String: Int64] = [:]

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
        configureSyncManager()
        configureDiscordRPC()
    }

    func configureSyncManager() {
        if settings.syncEnabled && !settings.syncFolderPath.isEmpty {
            syncManager.configure(folderPath: settings.syncFolderPath)
        } else {
            syncManager.configure(folderPath: nil)
        }
        syncManager.onRemoteDataChanged = { [weak self] in
            guard let self = self else { return }
            self.remoteMachines = self.syncManager.remoteMachines
            self.objectWillChange.send()
        }
    }

    func configureDiscordRPC() {
        discordRPC.setEnabled(settings.discordPresenceEnabled)
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
            var allHourly: [String: Int64] = [:]
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let localFmt = DateFormatter()
            localFmt.dateFormat = "yyyy-MM-dd-HH"
            localFmt.timeZone = .current

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
                    for (hour, tokens) in state.hourlyTokens {
                        allHourly[hour, default: 0] += tokens
                    }
                    continue
                }

                let existing = self.fileStates[path]
                let startOffset = existing?.offset ?? 0
                var fileCounts = existing?.modelTokens ?? [:]
                var fileHours = existing?.hourlyTokens ?? [:]

                guard let fh = FileHandle(forReadingAtPath: path) else { continue }
                defer { fh.closeFile() }

                fh.seek(toFileOffset: startOffset)
                let newData = fh.readDataToEndOfFile()
                guard !newData.isEmpty,
                      let text = String(data: newData, encoding: .utf8) else { continue }

                var bytesConsumed: Int = 0
                let lines = text.components(separatedBy: "\n")

                for (i, line) in lines.enumerated() {
                    if i == lines.count - 1 { break }
                    bytesConsumed += line.utf8.count + 1
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
                    let msgTotal = inp + out + cr + cc

                    var mc = fileCounts[model] ?? [0, 0, 0, 0]
                    mc[0] += inp; mc[1] += out; mc[2] += cr; mc[3] += cc
                    fileCounts[model] = mc

                    // Extract date+hour for time tracking (convert UTC to local)
                    if let ts = obj["timestamp"] as? String, ts.count >= 20,
                       let date = isoFmt.date(from: ts) {
                        let hourKey = localFmt.string(from: date)
                        fileHours[hourKey, default: 0] += msgTotal
                    }
                }

                self.fileStates[path] = JSONLFileState(
                    offset: startOffset + UInt64(bytesConsumed),
                    modelTokens: fileCounts,
                    hourlyTokens: fileHours
                )

                for (model, counts) in fileCounts {
                    var e = allUsage[model] ?? [0, 0, 0, 0]
                    for i in 0..<4 { e[i] += counts[i] }
                    allUsage[model] = e
                }
                for (hour, tokens) in fileHours {
                    allHourly[hour, default: 0] += tokens
                }
            }

            // Scan OpenClaw sessions
            let openclawDir = home.appendingPathComponent(".openclaw/agents")
            if fm.fileExists(atPath: openclawDir.path),
               let agentDirs = try? fm.contentsOfDirectory(at: openclawDir, includingPropertiesForKeys: nil) {
                for agentDir in agentDirs {
                    let sessionsFile = agentDir.appendingPathComponent("sessions/sessions.json")
                    guard let data = try? Data(contentsOf: sessionsFile),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    for (_, value) in json {
                        guard let session = value as? [String: Any] else { continue }
                        let inp = (session["inputTokens"] as? NSNumber)?.int64Value ?? 0
                        let out = (session["outputTokens"] as? NSNumber)?.int64Value ?? 0
                        if inp + out > 0 {
                            var mc = allUsage["openclaw"] ?? [0, 0, 0, 0]
                            mc[0] += inp; mc[1] += out
                            allUsage["openclaw"] = mc
                        }
                    }
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
            let aggregated = Self.aggregateTokenHistory(allHourly, period: self.settings.graphPeriod)

            DispatchQueue.main.async {
                self.liveModelUsage = result
                self.rawHourlyTokens = allHourly
                self.dailyTokenHistory = aggregated
                self.lastUpdated = Date()
                // Fix day start if it was set to 0 during early init
                if self.settings.dayStartTokens == 0 && self.totalTokens > 0 {
                    self.settings.dayStartTokens = self.totalTokens
                    self.settings.save()
                }
                self.watchJSONLFiles(paths: knownPaths)
                if self.settings.syncEnabled {
                    self.syncManager.writeLocalData(
                        modelUsage: result,
                        totalTokens: result.values.reduce(0) { $0 + $1.totalTokens }
                    )
                }
                NotificationManager.checkMilestones(
                    totalTokens: self.totalTokens, settings: &self.settings
                )
                NotificationManager.checkBudget(
                    todayTokens: self.todayTokens,
                    budget: self.settings.dailyBudget,
                    settings: &self.settings
                )
                if self.settings.discordPresenceEnabled {
                    let todayStr = Self.todayString()
                    let todayReal = self.rawHourlyTokens.filter { $0.key.hasPrefix(todayStr) }.values.reduce(0, +)
                    let topModel = self.modelBreakdown.first?.name ?? "Claude"
                    self.discordRPC.updateActivity(
                        details: "Lifetime: \(formatCompact(self.totalTokens)) tokens",
                        state: "Today: \(formatCompact(todayReal)) | \(topModel)"
                    )
                }
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

    // MARK: Graph Aggregation

    func recomputeGraph() {
        dailyTokenHistory = Self.aggregateTokenHistory(rawHourlyTokens, period: settings.graphPeriod)
    }

    static func aggregateTokenHistory(_ hourly: [String: Int64], period: String) -> [(date: String, tokens: Int64)] {
        guard !hourly.isEmpty else { return [] }
        var grouped: [String: Int64] = [:]

        switch period {
        case "hourly":
            // Last 24 hours, key as-is "yyyy-MM-dd-HH"
            grouped = hourly
            let sorted = grouped.sorted { $0.key < $1.key }.suffix(24)
            return sorted.map { (date: $0.key, tokens: $0.value) }

        case "weekly":
            // Group by ISO week: "yyyy-Www"
            let cal = Calendar(identifier: .iso8601)
            for (key, tokens) in hourly {
                let dayStr = String(key.prefix(10))
                let parts = dayStr.split(separator: "-")
                guard parts.count == 3,
                      let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
                      let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { continue }
                let week = cal.component(.weekOfYear, from: date)
                let weekYear = cal.component(.yearForWeekOfYear, from: date)
                let weekKey = String(format: "%04d-W%02d", weekYear, week)
                grouped[weekKey, default: 0] += tokens
            }
            let sorted = grouped.sorted { $0.key < $1.key }.suffix(12)
            return sorted.map { (date: $0.key, tokens: $0.value) }

        case "monthly":
            // Group by "yyyy-MM"
            for (key, tokens) in hourly {
                let monthKey = String(key.prefix(7))
                grouped[monthKey, default: 0] += tokens
            }
            let sorted = grouped.sorted { $0.key < $1.key }.suffix(12)
            return sorted.map { (date: $0.key, tokens: $0.value) }

        default: // "daily"
            for (key, tokens) in hourly {
                let dayKey = String(key.prefix(10))
                grouped[dayKey, default: 0] += tokens
            }
            let sorted = grouped.sorted { $0.key < $1.key }.suffix(14)
            return sorted.map { (date: $0.key, tokens: $0.value) }
        }
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
        let local: [String: ModelUsage]?
        if let live = liveModelUsage, !live.isEmpty {
            local = live
        } else {
            local = stats?.modelUsage
        }
        guard settings.syncEnabled else { return local }
        guard let localUsage = local else {
            let remote = syncManager.combinedRemoteUsage
            return remote.isEmpty ? nil : remote
        }
        let remoteUsage = syncManager.combinedRemoteUsage
        guard !remoteUsage.isEmpty else { return localUsage }
        var merged = localUsage
        for (model, remote) in remoteUsage {
            if let existing = merged[model] {
                merged[model] = ModelUsage(
                    inputTokens: existing.inputTokens + remote.inputTokens,
                    outputTokens: existing.outputTokens + remote.outputTokens,
                    cacheReadInputTokens: existing.cacheReadInputTokens + remote.cacheReadInputTokens,
                    cacheCreationInputTokens: existing.cacheCreationInputTokens + remote.cacheCreationInputTokens,
                    webSearchRequests: 0, costUSD: nil, contextWindow: nil, maxOutputTokens: nil
                )
            } else {
                merged[model] = remote
            }
        }
        return merged
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
        if raw == "openclaw" { return "OpenClaw" }
        return raw
    }

    static func modelColor(_ raw: String) -> Color {
        if raw.contains("opus-4-6") { return .orange }
        if raw.contains("opus-4-5") { return .pink }
        if raw.contains("sonnet") { return .blue }
        if raw.contains("haiku") { return .green }
        if raw == "openclaw" { return .red }
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
                if !store.dailyTokenHistory.isEmpty {
                    UsageGraph(data: store.dailyTokenHistory, period: store.settings.graphPeriod)
                }
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
            if store.settings.syncEnabled && !store.remoteMachines.isEmpty {
                Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green.opacity(0.4))
            }
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
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.4), value: store.todayTokens)
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
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.4), value: store.estimatedCost)
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

// MARK: - Usage Graph

struct UsageGraph: View {
    let data: [(date: String, tokens: Int64)]
    let period: String
    @State private var hoveredIndex: Int? = nil

    private var maxTokens: Int64 {
        data.map(\.tokens).max() ?? 1
    }

    private var periodLabel: String {
        switch period {
        case "hourly": return "Hourly"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        default: return "Daily"
        }
    }

    private var trailingLabel: String {
        if let i = hoveredIndex, i < data.count {
            return "\(formatLabel(data[i].date)): \(formatCompact(data[i].tokens))"
        }
        switch period {
        case "hourly": return "last \(data.count)h"
        case "weekly": return "last \(data.count)w"
        case "monthly": return "last \(data.count)mo"
        default: return "last \(data.count)d"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(periodLabel) Usage")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text(trailingLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(hoveredIndex != nil ? .white.opacity(0.5) : .white.opacity(0.18))
                    .animation(.easeOut(duration: 0.15), value: hoveredIndex)
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.offset) { offset, entry in
                    let fraction = CGFloat(entry.tokens) / CGFloat(maxTokens)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hoveredIndex == offset ? barColor(fraction: fraction).opacity(1.0) : barColor(fraction: fraction))
                        .frame(height: max(2, 40 * fraction))
                        .frame(maxWidth: .infinity)
                        .onHover { hovering in
                            hoveredIndex = hovering ? offset : nil
                        }
                }
            }
            .frame(height: 40)

            HStack {
                Text(formatLabel(data.first?.date))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.15))
                Spacer()
                Text(formatLabel(data.last?.date))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.15))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func barColor(fraction: CGFloat) -> Color {
        if fraction > 0.8 { return .orange.opacity(0.6) }
        if fraction > 0.5 { return .cyan.opacity(0.5) }
        return .cyan.opacity(0.35)
    }

    private func formatLabel(_ key: String?) -> String {
        guard let key = key else { return "" }
        switch period {
        case "hourly":
            // "yyyy-MM-dd-HH" -> "3pm"
            guard key.count >= 13 else { return key }
            let hh = String(key.suffix(2))
            guard let h = Int(hh) else { return hh }
            if h == 0 { return "12a" }
            if h < 12 { return "\(h)a" }
            if h == 12 { return "12p" }
            return "\(h - 12)p"
        case "weekly":
            // "yyyy-Www" -> "W6"
            if key.contains("W") { return String(key.suffix(from: key.index(key.startIndex, offsetBy: 5))) }
            return key
        case "monthly":
            // "yyyy-MM" -> "Jan"
            let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            guard key.count >= 7, let m = Int(key.suffix(2)), m >= 1, m <= 12 else { return key }
            return months[m - 1]
        default:
            // "yyyy-MM-dd" -> "02/11"
            guard key.count >= 10 else { return key }
            let parts = key.split(separator: "-")
            guard parts.count >= 3 else { return key }
            return "\(parts[1])/\(parts[2])"
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
                .contentTransition(.numericText())
        }
        .animation(.spring(duration: 0.4), value: value)
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
    @State private var settingsLoaded: Bool = false

    // Sync
    @State private var syncEnabled: Bool = false
    @State private var syncFolderPath: String = ""

    // Graph
    @State private var graphPeriod: String = "daily"

    // Discord
    @State private var discordPresenceEnabled: Bool = false

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
                    syncSection
                    discordSection
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
        .onAppear {
            loadValues()
            DispatchQueue.main.async { settingsLoaded = true }
        }
        .onChange(of: settingsKey) { autoSave() }
    }

    private var settingsKey: String {
        "\(launchAtLogin)\(alwaysOnTop)\(showOnAllSpaces)\(startMinimized)\(widgetOpacity)\(showCostEstimate)\(showModelBreakdown)\(showSessionStats)\(graphPeriod)\(budgetText)\(warningThreshold)\(notificationsEnabled)\(refreshInterval)\(syncEnabled)\(syncFolderPath)\(discordPresenceEnabled)"
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Graph Period")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 4) {
                    ForEach(["hourly", "daily", "weekly", "monthly"], id: \.self) { period in
                        Button(action: { graphPeriod = period }) {
                            Text(period.prefix(1).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(graphPeriod == period ? .white.opacity(0.9) : .white.opacity(0.35))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(graphPeriod == period ? .white.opacity(0.12) : .white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
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

    // MARK: Sync

    private var syncSection: some View {
        VStack(spacing: 0) {
            sectionHeader("SYNC")
            toggleRow("Enable Sync", isOn: $syncEnabled)

            if syncEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sync Folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        Text(syncFolderPath.isEmpty ? "Not set" : abbreviatePath(syncFolderPath))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(syncFolderPath.isEmpty ? 0.25 : 0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: chooseSyncFolder) {
                            Text("Browse")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)

                if !store.remoteMachines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connected Machines")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        ForEach(Array(store.remoteMachines.enumerated()), id: \.offset) { _, machine in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(machineStatusColor(machine))
                                    .frame(width: 6, height: 6)
                                Text(machine.machineName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                Text(formatCompact(machine.totalTokens))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                } else if !syncFolderPath.isEmpty {
                    Text("No other machines found yet")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.2))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }

                HStack {
                    Text("This machine: \(MachineIdentity.machineName)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.18))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Discord

    private var discordSection: some View {
        VStack(spacing: 0) {
            sectionHeader("DISCORD")
            toggleRow("Rich Presence", isOn: $discordPresenceEnabled)
            if discordPresenceEnabled {
                Text("Shows token stats in your Discord status")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
        }
    }

    private func chooseSyncFolder() {
        SyncFolderPicker.chooseFolder(current: syncFolderPath) { path in
            if let path = path { syncFolderPath = path }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    private func machineStatusColor(_ machine: SyncPayload) -> Color {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: machine.lastUpdated) else { return .gray }
        let age = Date().timeIntervalSince(date)
        if age < 300 { return .green }
        if age < 3600 { return .yellow }
        return .gray
    }

    // MARK: Footer

    private var footerButtons: some View {
        Button(action: onClose) {
            Text("Done")
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
        syncEnabled = s.syncEnabled
        syncFolderPath = s.syncFolderPath
        graphPeriod = s.graphPeriod
        discordPresenceEnabled = s.discordPresenceEnabled
    }

    private func autoSave() {
        guard settingsLoaded else { return }
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
        store.settings.syncEnabled = syncEnabled
        store.settings.syncFolderPath = syncFolderPath
        store.settings.graphPeriod = graphPeriod
        store.settings.discordPresenceEnabled = discordPresenceEnabled
        store.settings.save()
        store.configureSyncManager()
        store.configureDiscordRPC()
        store.recomputeGraph()
        store.setLaunchAtLogin(launchAtLogin)
        store.startAutoRefresh()
        store.objectWillChange.send()
        store.onSettingsChanged?()
        store.onSizeChange?()
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
