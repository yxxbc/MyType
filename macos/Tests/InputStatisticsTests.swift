import Foundation

func checkInputStatistics() {
    check(InputStatistics.countHan(in: "你好𠮷〇、ABC 123🧪かな") == 4, "统计：只数汉字（含扩展区）")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let beforeDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23))!
    let afterDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 4))!
    var statistics = InputStatistics()
    statistics.record(characters: 3, at: beforeDST, calendar: calendar)
    statistics.record(characters: 1, at: beforeDST, calendar: calendar)
    statistics.record(characters: 0, at: afterDST, calendar: calendar)
    statistics.record(characters: 2, at: afterDST, calendar: calendar)
    let expected: [InputStatistics.Count] = [.init(characters: 4, commits: 2), .init(), .init(characters: 2, commits: 1)]
    check(statistics.recentDays(3, endingAt: afterDST, calendar: calendar).map(\.count) == expected,
          "统计：按本地日期聚合，跨夏令时和空白日")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try statistics.write(in: dir)
        let read = InputStatistics.read(in: dir)
        check(read.recentDays(3, endingAt: afterDST, calendar: calendar).map(\.count) == expected, "统计：磁盘日计数往返")
        let later = calendar.date(byAdding: .day, value: 100, to: afterDST)!
        statistics.record(characters: 5, at: later, calendar: calendar)
        let retained = statistics.recentDays(105, endingAt: later, calendar: calendar).map(\.count.characters)
        check(retained.reduce(0, +) == 5, "统计：新日期写入时回收 90 天以前的数据")
    } catch {
        check(false, "统计：写入测试目录", String(describing: error))
    }
}
