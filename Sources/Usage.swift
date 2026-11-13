import Foundation

// MARK: - Raw records

/// One model reply, as logged in a Claude Code transcript.
struct Reply: Codable {
    let day: String        // local yyyy-MM-dd
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    var total: Int { input + output + cacheRead + cacheWrite }
}

/// What one transcript file contributes, cached by its size and modification time.
struct LogEntry: Codable {
    let key: String
    let session: String
    let isSubagent: Bool
    let firstAt: Double?
    let lastAt: Double?
    let replies: [String: Reply]
}

struct LogCache: Codable {
    var version: Int
    var files: [String: LogEntry]
}

// MARK: - Reading the transcripts

enum LogReader {
    static let cacheVersion = 3
    static let projects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Usage Stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("cache.json")
    }

    private static let usageNeedle = Data("\"usage\"".utf8)
    private static let stampNeedle = Data("\"timestamp\":\"".utf8)

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    static func loadCache() -> LogCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(LogCache.self, from: data),
              cache.version == cacheVersion
        else { return LogCache(version: cacheVersion, files: [:]) }
        return cache
    }

    static func saveCache(_ cache: LogCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Reads every transcript, rereading only files whose size or mtime changed.
    static func scan(previous: LogCache) -> LogCache {
        var next = LogCache(version: cacheVersion, files: [:])
        guard let walker = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return next }

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            let mtime = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let key = "\(size):\(mtime)"
            if let old = previous.files[url.path], old.key == key {
                next.files[url.path] = old
                continue
            }
            if let entry = read(url, key: key) {
                next.files[url.path] = entry
            }
        }
        return next
    }

    private static func timestamp(in line: Data) -> Double? {
        guard let r = line.range(of: stampNeedle) else { return nil }
        let start = r.upperBound
        guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        guard let s = String(data: line[start..<end], encoding: .utf8) else { return nil }
        return parseDate(s)?.timeIntervalSince1970
    }

    static func read(_ url: URL, key: String) -> LogEntry? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var replies: [String: Reply] = [:]
        var first: Double?
        var last: Double?

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let t = timestamp(in: line) {
                if first == nil { first = t }
                last = t
            }
            guard line.range(of: usageNeedle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let id = message["id"] as? String,
                  let stamp = object["timestamp"] as? String,
                  let date = parseDate(stamp)
            else { continue }
            let model = (message["model"] as? String) ?? "unknown"
            if model == "<synthetic>" { continue }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            // A streamed reply is logged once per content block; the last copy wins.
            replies[id] = Reply(
                day: dayFormatter.string(from: date),
                model: model,
                input: n("input_tokens"),
                output: n("output_tokens"),
                cacheRead: n("cache_read_input_tokens"),
                cacheWrite: n("cache_creation_input_tokens")
            )
        }

        return LogEntry(
            key: key,
            session: url.deletingPathExtension().lastPathComponent,
            isSubagent: url.path.contains("/subagents/"),
            firstAt: first,
            lastAt: last,
            replies: replies
        )
    }
}

// MARK: - Summaries

enum UsageRange: String, CaseIterable, Identifiable {
    case all = "All time"
    case month = "Last 30 days"
    case week = "Last 7 days"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .all: return nil
        case .month: return 30
        case .week: return 7
        }
    }
}

struct TokenTotals {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    mutating func add(_ r: Reply) {
        input += r.input; output += r.output; cacheRead += r.cacheRead; cacheWrite += r.cacheWrite
    }
}

struct ModelShare: Identifiable {
    let id: String
    let name: String
    let tokens: Int
    let replies: Int
}

struct Summary {
    var tokens = TokenTotals()
    var replies = 0
    var sessions = 0
    var longestSession: TimeInterval = 0
    var activeDays = 0
    var spanDays = 0
    var mostActiveDay: String?
    var models: [ModelShare] = []
    var favoriteModel: String? { models.first?.name }
}

/// All replies, deduplicated across files, plus each main session's span.
struct UsageData {
    var replies: [String: Reply] = [:]
    var replyFiles: [String: String] = [:]              // reply id -> session
    var sessions: [String: (first: Double, last: Double)] = [:]
    var perDay: [String: Int] = [:]
    var firstDay: String?

    init() {}

    init(cache: LogCache) {
        for (_, entry) in cache.files {
            for (id, r) in entry.replies {
                replies[id] = r
                if !entry.isSubagent { replyFiles[id] = entry.session }
            }
            if !entry.isSubagent, !entry.replies.isEmpty, let f = entry.firstAt, let l = entry.lastAt {
                let old = sessions[entry.session]
                sessions[entry.session] = (min(f, old?.first ?? f), max(l, old?.last ?? l))
            }
        }
        for r in replies.values {
            perDay[r.day, default: 0] += r.total
            if firstDay == nil || r.day < firstDay! { firstDay = r.day }
        }
    }

    var isEmpty: Bool { replies.isEmpty }

    func summary(for range: UsageRange, today: Date = Date()) -> Summary {
        var s = Summary()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: today)
        var cutoffDay: String?
        if let d = range.days, let start = cal.date(byAdding: .day, value: -(d - 1), to: startOfToday) {
            cutoffDay = LogReader.dayFormatter.string(from: start)
        }
        func inRange(_ day: String) -> Bool { cutoffDay.map { day >= $0 } ?? true }

        var byModel: [String: (tokens: Int, replies: Int)] = [:]
        var byDay: [String: Int] = [:]
        var sessionsSeen = Set<String>()
        for (id, r) in replies where inRange(r.day) {
            s.tokens.add(r)
            s.replies += 1
            byModel[r.model, default: (0, 0)].tokens += r.total
            byModel[r.model, default: (0, 0)].replies += 1
            byDay[r.day, default: 0] += r.total
            if let session = replyFiles[id] { sessionsSeen.insert(session) }
        }

        s.sessions = sessionsSeen.count
        s.longestSession = sessionsSeen.compactMap { sessions[$0] }.map { $0.last - $0.first }.max() ?? 0
        s.activeDays = byDay.count
        s.mostActiveDay = byDay.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key

        if let days = range.days {
            s.spanDays = days
        } else if let first = firstDay, let firstDate = LogReader.dayFormatter.date(from: first) {
            let span = cal.dateComponents([.day], from: cal.startOfDay(for: firstDate), to: startOfToday).day ?? 0
            s.spanDays = span + 1
        }

        s.models = byModel
            .map { ModelShare(id: $0.key, name: Format.model($0.key), tokens: $0.value.tokens, replies: $0.value.replies) }
            .sorted { $0.tokens > $1.tokens }
        return s
    }
}

// MARK: - Formatting

enum Format {
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        func short(_ x: Double, _ unit: String) -> String {
            let s = x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if v >= 1e9 { return short(v / 1e9, "B") }
        if v >= 1e6 { return short(v / 1e6, "M") }
        if v >= 1e3 { return short(v / 1e3, "k") }
        return "\(n)"
    }

    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(max(mins, 0))m"
    }

    static func shortDay(_ day: String?) -> String {
        guard let day, let d = LogReader.dayFormatter.date(from: day) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    static func longDay(_ day: String) -> String {
        guard let d = LogReader.dayFormatter.date(from: day) else { return day }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy"
        return f.string(from: d)
    }

    /// claude-opus-5-5 -> "Opus 5.5"; claude-3-5-sonnet-20241022 -> "Sonnet 3.5".
    static func model(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 3 else { return id }
        let rest = parts.dropFirst().filter { !($0.count == 8 && Int($0) != nil) }
        let words = rest.filter { Int($0) == nil }
        let numbers = rest.filter { Int($0) != nil && $0.count <= 2 }
        guard let name = words.first, !numbers.isEmpty else { return id }
        return name.prefix(1).uppercased() + name.dropFirst() + " " + numbers.joined(separator: ".")
    }

    /// "~98× the tokens in A Christmas Carol", using ~37,500 tokens for the book.
    static func bookComparison(_ tokens: Int) -> String? {
        guard tokens > 0 else { return nil }
        let ratio = Double(tokens) / 37_500
        let text: String
        if ratio < 1 {
            text = "~\(max(1, Int((ratio * 100).rounded())))% of the tokens in"
        } else if ratio < 10 {
            text = "~" + String(format: "%.1f", ratio).replacingOccurrences(of: ".0", with: "") + "× the tokens in"
        } else if ratio < 100 {
            text = "~\(Int(ratio.rounded()))× the tokens in"
        } else {
            text = "~\(Int((ratio / 10).rounded()) * 10)× the tokens in"
        }
        return "Your input and output are \(text) A Christmas Carol."
    }
}
