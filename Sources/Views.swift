import AppKit
import SwiftUI

// MARK: - Store

final class UsageStore: ObservableObject {
    @Published var data = UsageData()
    @Published var isLoaded = false

    private var cache = LogCache(version: LogReader.cacheVersion, files: [:])  // touched on `queue` only
    private let queue = DispatchQueue(label: "usage-stats.scan", qos: .utility)
    private var isQueued = false
    private var lastScan = Date.distantPast
    private var timer: Timer?

    /// Loads everything on the calling thread (snapshots only).
    func loadNow() {
        let next = LogReader.scan(previous: LogReader.loadCache())
        data = UsageData(cache: next)
        isLoaded = true
    }

    func start() {
        queue.async {
            let cached = LogReader.loadCache()
            self.cache = cached
            if !cached.files.isEmpty {
                let data = UsageData(cache: cached)
                DispatchQueue.main.async {
                    self.data = data
                    self.isLoaded = true
                }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Recounts in the background; calls sooner than `minInterval` after the last are skipped.
    func refresh(minInterval: TimeInterval = 0) {
        guard !isQueued, Date().timeIntervalSince(lastScan) >= minInterval else { return }
        isQueued = true
        queue.async {
            let next = LogReader.scan(previous: self.cache)
            self.cache = next
            LogReader.saveCache(next)
            let data = UsageData(cache: next)
            DispatchQueue.main.async {
                self.data = data
                self.isLoaded = true
                self.isQueued = false
                self.lastScan = Date()
            }
        }
    }
}

// MARK: - Theme

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct Theme {
    let isDark: Bool
    var card: Color { isDark ? Color(hex: 0x1C1C1B) : Color(hex: 0xFFFFFF) }
    var border: Color { isDark ? Color(hex: 0x333332) : Color(hex: 0xE3E2DE) }
    var primary: Color { isDark ? Color(hex: 0xF0EFEA) : Color(hex: 0x1F1E1D) }
    var secondary: Color { isDark ? Color(hex: 0xA3A29C) : Color(hex: 0x6F6E69) }
    var divider: Color { isDark ? Color(hex: 0x3A3A38) : Color(hex: 0xE3E2DE) }
    var pill: Color { isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }
    var hoverFill: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    /// Heatmap squares: none, then least to most.
    var levels: [Color] {
        isDark
            ? [Color(hex: 0x2E2E2D), Color(hex: 0x27509F), Color(hex: 0x3168CC), Color(hex: 0x4A8BEC), Color(hex: 0xA9C8F5)]
            : [Color(hex: 0xECEBE8), Color(hex: 0xBFD7F8), Color(hex: 0x86B3F1), Color(hex: 0x3F7FE3), Color(hex: 0x1D4FA8)]
    }
    var accent: Color { isDark ? Color(hex: 0x4A8BEC) : Color(hex: 0x3F7FE3) }
}

// MARK: - Heatmap

struct HeatCell: Equatable {
    let day: String
    let tokens: Int
    let level: Int
}

struct HeatColumn {
    let cells: [HeatCell?]     // 7 rows, Sunday first; nil after today
    let monthLabel: String?
}

enum HeatmapBuilder {
    static func columns(perDay: [String: Int], weeks: Int, today: Date = Date()) -> [HeatColumn] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: start) - 1   // Sunday = 0
        guard let first = cal.date(byAdding: .day, value: -(weekday + (weeks - 1) * 7), to: start) else { return [] }

        let values = perDay.values.filter { $0 > 0 }.sorted()
        func cut(_ q: Double) -> Int {
            values.isEmpty ? 0 : values[min(values.count - 1, Int(q * Double(values.count)))]
        }
        let cuts = [cut(0.25), cut(0.5), cut(0.75)]
        func level(_ n: Int) -> Int {
            if n <= 0 { return 0 }
            if n <= cuts[0] { return 1 }
            if n <= cuts[1] { return 2 }
            if n <= cuts[2] { return 3 }
            return 4
        }

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        var columns: [HeatColumn] = []
        var lastMonth = -1
        var lastLabelAt = -10
        for w in 0..<weeks {
            var cells: [HeatCell?] = []
            var label: String?
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: first), date <= start else {
                    cells.append(nil)
                    continue
                }
                if d == 0 {
                    let month = cal.component(.month, from: date)
                    if month != lastMonth {
                        // Label a month at its first full column, with room for the text.
                        if cal.component(.day, from: date) <= 7, w - lastLabelAt >= 3 {
                            label = monthFormatter.string(from: date)
                            lastLabelAt = w
                        }
                        lastMonth = month
                    }
                }
                let day = LogReader.dayFormatter.string(from: date)
                let tokens = perDay[day] ?? 0
                cells.append(HeatCell(day: day, tokens: tokens, level: level(tokens)))
            }
            columns.append(HeatColumn(cells: cells, monthLabel: label))
        }
        return columns
    }
}

struct HeatmapView: View {
    let perDay: [String: Int]
    let theme: Theme
    let width: CGFloat

    @State private var hovered: HeatCell?

    private let cell: CGFloat = 12
    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 32
    private var pitch: CGFloat { cell + gap }
    private var weeks: Int { max(4, Int((width - labelWidth + gap) / pitch)) }

    var body: some View {
        let columns = HeatmapBuilder.columns(perDay: perDay, weeks: weeks)
        let gridWidth = CGFloat(columns.count) * pitch - gap

        VStack(alignment: .leading, spacing: 6) {
            // Month labels
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: labelWidth + gridWidth, height: 14)
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    if let label = column.monthLabel {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondary)
                            .fixedSize()
                            .offset(x: labelWidth + CGFloat(index) * pitch)
                    }
                }
            }

            HStack(alignment: .top, spacing: 0) {
                // Weekday labels
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 1 ? "Mon" : row == 3 ? "Wed" : row == 5 ? "Fri" : "")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondary)
                            .frame(width: labelWidth, height: cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                if let item = column.cells[row] {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(theme.levels[item.level])
                                        .frame(width: cell, height: cell)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .strokeBorder(theme.primary.opacity(hovered == item ? 0.7 : 0), lineWidth: 1)
                                        )
                                        .onHover { inside in
                                            if inside { hovered = item } else if hovered == item { hovered = nil }
                                        }
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Less").font(.system(size: 11)).foregroundColor(theme.secondary)
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(theme.levels[i])
                            .frame(width: 9, height: 9)
                    }
                }
                Text("More").font(.system(size: 11)).foregroundColor(theme.secondary)
            }
            .frame(width: labelWidth + gridWidth)
            .padding(.top, 2)
        }
    }

    private var caption: String {
        guard let h = hovered else { return "" }
        return h.tokens > 0
            ? "\(Format.tokens(h.tokens)) tokens · \(Format.longDay(h.day))"
            : "No usage · \(Format.longDay(h.day))"
    }
}

// MARK: - Rows

struct StatRow: View {
    let label: String
    let value: String
    let theme: Theme
    var emphasized = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundColor(emphasized ? theme.primary : theme.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundColor(theme.primary)
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: emphasized ? .medium : .regular))
            .lineLimit(1)
            .padding(.vertical, 8)
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let trailing: String
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(theme.primary)
                Spacer()
                Text(trailing).font(.system(size: 13)).foregroundColor(theme.secondary)
            }
            .padding(.bottom, 8)
            Rectangle().fill(theme.divider).frame(height: 1)
        }
    }
}

// MARK: - Card

enum CardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tokens = "Tokens"
    case models = "Models"
    var id: String { rawValue }
}

struct CardView: View {
    @ObservedObject var store: UsageStore
    let onHide: () -> Void
    let onSize: (CGSize) -> Void
    var forcedTab: CardTab? = nil      // snapshots only

    @Environment(\.colorScheme) private var scheme
    @AppStorage("tab") private var tabName = CardTab.overview.rawValue
    @AppStorage("range") private var rangeName = UsageRange.all.rawValue
    @State private var didCopy = false
    @Namespace private var tabSpace

    static let width: CGFloat = 420
    private let padding: CGFloat = 22
    private var inner: CGFloat { Self.width - padding * 2 }

    private var tab: CardTab { forcedTab ?? CardTab(rawValue: tabName) ?? .overview }
    private var range: UsageRange { UsageRange(rawValue: rangeName) ?? .all }

    var body: some View {
        let theme = Theme(isDark: scheme == .dark)
        let summary = store.data.summary(for: range)

        VStack(alignment: .leading, spacing: 0) {
            header(theme, summary)
            controls(theme).padding(.top, 14)

            Group {
                if !store.isLoaded {
                    placeholder("Counting your usage…", theme)
                } else if store.data.isEmpty {
                    placeholder("No Claude Code usage found yet.", theme)
                } else {
                    switch tab {
                    case .overview: overview(theme, summary)
                    case .tokens: tokens(theme, summary)
                    case .models: models(theme, summary)
                    }
                }
            }
            .padding(.top, 16)
        }
        .padding(padding)
        .frame(width: Self.width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { onSize(g.size) }
                    .onChange(of: g.size) { onSize($0) }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private func header(_ theme: Theme, _ summary: Summary) -> some View {
        HStack(spacing: 4) {
            Text("Stats")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.primary)
            Spacer()
            IconButton(symbol: didCopy ? "checkmark" : "square.on.square", help: "Copy stats", theme: theme) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText(summary), forType: .string)
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
            }
            IconButton(symbol: "xmark", help: "Hide (reopen from the menu bar)", theme: theme, action: onHide)
        }
    }

    private func controls(_ theme: Theme) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(CardTab.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tabName = item.rawValue }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: tab == item ? .medium : .regular))
                            .foregroundColor(tab == item ? theme.primary : theme.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                ZStack {
                                    if tab == item {
                                        Capsule().fill(theme.pill).matchedGeometryEffect(id: "pill", in: tabSpace)
                                    }
                                }
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, -11)

            Spacer()

            Menu {
                ForEach(UsageRange.allCases) { item in
                    Button {
                        rangeName = item.rawValue
                    } label: {
                        if item == range { Label(item.rawValue, systemImage: "checkmark") } else { Text(item.rawValue) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(range.rawValue).font(.system(size: 13))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(theme.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func placeholder(_ text: String, _ theme: Theme) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondary)
            .frame(width: inner, height: 120)
    }

    // MARK: Tabs

    private func overview(_ theme: Theme, _ s: Summary) -> some View {
        let gutter: CGFloat = 22
        let column = (inner - gutter) / 2
        return VStack(alignment: .leading, spacing: 18) {
            HeatmapView(perDay: store.data.perDay, theme: theme, width: inner)
            HStack(alignment: .top, spacing: gutter) {
                VStack(spacing: 0) {
                    StatRow(label: "Favorite model", value: s.favoriteModel ?? "—", theme: theme)
                    StatRow(label: "Sessions", value: "\(s.sessions)", theme: theme)
                    StatRow(label: "Active days", value: "\(s.activeDays)/\(s.spanDays)", theme: theme)
                }
                .frame(width: column)
                VStack(spacing: 0) {
                    StatRow(label: "Total tokens", value: Format.tokens(s.tokens.total), theme: theme)
                    StatRow(label: "Longest session", value: s.sessions > 0 ? Format.duration(s.longestSession) : "—", theme: theme)
                    StatRow(label: "Most active day", value: Format.shortDay(s.mostActiveDay), theme: theme)
                }
                .frame(width: column)
            }
        }
    }

    private func tokens(_ theme: Theme, _ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Tokens", trailing: range.rawValue, theme: theme)
            StatRow(label: "Input", value: Format.tokens(s.tokens.input), theme: theme)
            StatRow(label: "Output", value: Format.tokens(s.tokens.output), theme: theme)
            StatRow(label: "Cache read", value: Format.tokens(s.tokens.cacheRead), theme: theme)
            StatRow(label: "Cache write", value: Format.tokens(s.tokens.cacheWrite), theme: theme)
            StatRow(label: "Total", value: Format.tokens(s.tokens.total), theme: theme, emphasized: true)
            if let line = Format.bookComparison(s.tokens.input + s.tokens.output) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
        .frame(width: inner, alignment: .leading)
    }

    private func models(_ theme: Theme, _ s: Summary) -> some View {
        let total = max(1, s.tokens.total)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Models", trailing: range.rawValue, theme: theme)
            if s.models.isEmpty {
                Text("No usage in this period.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondary)
                    .padding(.vertical, 14)
            }
            ForEach(s.models) { model in
                let share = Double(model.tokens) / Double(total)
                VStack(spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.name).foregroundColor(theme.primary)
                        Spacer(minLength: 8)
                        Text("\(Format.tokens(model.tokens))  ·  \(percent(share))")
                            .foregroundColor(theme.secondary)
                            .monospacedDigit()
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.levels[0])
                            Capsule().fill(theme.accent).frame(width: max(3, g.size.width * share))
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.vertical, 10)
                Rectangle().fill(theme.divider).frame(height: 1)
            }
        }
        .frame(width: inner, alignment: .leading)
    }

    private func percent(_ share: Double) -> String {
        let p = share * 100
        if p > 0, p < 1 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }

    private func copyText(_ s: Summary) -> String {
        """
        Claude usage — \(range.rawValue)
        Total tokens: \(Format.tokens(s.tokens.total))
        Input: \(Format.tokens(s.tokens.input)) · Output: \(Format.tokens(s.tokens.output))
        Cache read: \(Format.tokens(s.tokens.cacheRead)) · Cache write: \(Format.tokens(s.tokens.cacheWrite))
        Favorite model: \(s.favoriteModel ?? "—")
        Sessions: \(s.sessions) · Active days: \(s.activeDays)/\(s.spanDays)
        Longest session: \(Format.duration(s.longestSession)) · Most active day: \(Format.shortDay(s.mostActiveDay))
        """
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let theme: Theme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? theme.primary : theme.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovered ? theme.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
