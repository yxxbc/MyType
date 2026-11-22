import Foundation

/// 只存日计数，不保存输入内容、程序名或键位。由输入法进程写入，设置窗口只读。
struct InputStatistics: Codable {
    struct Count: Codable, Equatable {
        var characters = 0
        var commits = 0
    }

    struct Day: Identifiable {
        let date: Date
        let count: Count
        var id: Date { date }
    }

    static let fileName = "input-statistics.json"
    /// 保留最近多少天（设置页可以显示 7/14/30/90 天，超过这个数的旧数据会在下次写入时清掉）。
    static let retentionDays = 90
    private var counts: [Int: Count] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case counts
    }

    /// 缺字段按 0 读：以后加了新字段，旧文件还能读出来，不至于整份统计归零。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counts = (try? container.decode([Int: Count].self, forKey: .counts)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counts, forKey: .counts)
    }

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func read(in directory: URL) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let statistics = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return statistics
    }

    func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private static func key(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    static func countHan(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            switch scalar.value {
            case 0x3007, 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF, 0x30000...0x3FFFF:
                if scalar.properties.isIdeographic { count += 1 }
            default: break
            }
        }
    }

    mutating func record(characters: Int, at date: Date = Date(), calendar: Calendar = localCalendar) {
        guard characters > 0 else { return }
        let key = Self.key(date, calendar)
        if counts[key] == nil,
           let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: date) {
            let earliest = Self.key(cutoff, calendar)
            counts = counts.filter { $0.key >= earliest && $0.key <= key }
        }
        counts[key, default: Count()].characters += characters
        counts[key, default: Count()].commits += 1
    }

    func recentDays(_ length: Int, endingAt date: Date = Date(), calendar: Calendar = localCalendar) -> [Day] {
        guard length > 0 else { return [] }
        let start = calendar.startOfDay(for: date)
        return (0..<length).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            return Day(date: day, count: counts[Self.key(day, calendar)] ?? Count())
        }
    }
}
