// 学习数据（user.tsv、history.tsv）的统计、清除请求和进程间通知。
//
// 设置窗口是另一个进程：它不能直接清输入法内存里的学习数据。清除时先写一个请求文件，
// 再发 DistributedNotification；输入法收到通知（或者下一次按键看到请求文件）后清内存、存空文件。
// 输入法没在跑时请求文件留在数据目录，下次启动时消费。

import Foundation

public enum LearningData {
    public enum Kind {
        case learning
        case statistics

        var requestFileName: String {
            switch self {
            case .learning: return ".clear-learning"
            case .statistics: return ".clear-statistics"
            }
        }

        var notification: Notification.Name {
            switch self {
            case .learning:
                return Notification.Name("io.github.yxxbc.inputmethod.MyType.ClearLearning")
            case .statistics:
                return Notification.Name("io.github.yxxbc.inputmethod.MyType.ClearStatistics")
            }
        }
    }

    public struct Counts: Equatable {
        /// user.tsv 里的用户词
        public var userWords = 0
        /// history.tsv 里选过的词
        public var historyWords = 0
        /// history.tsv 里的词搭配
        public var pairs = 0

        public init() {}
    }

    public static func counts(in directory: URL) -> Counts {
        var counts = Counts()
        if let text = try? String(contentsOf: directory.appendingPathComponent("user.tsv"), encoding: .utf8) {
            counts.userWords = text.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                .count
        }
        if let text = try? String(contentsOf: directory.appendingPathComponent("history.tsv"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard let kind = cols.first else { continue }
                if kind == "w" { counts.historyWords += 1 }
                if kind == "p" { counts.pairs += 1 }
            }
        }
        return counts
    }

    /// 记下「要清除」，让另一个进程下一次检查时处理（同一秒重复点也只留一个请求）。
    public static func requestReset(_ kind: Kind, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(kind.requestFileName)
        try? Data(UUID().uuidString.utf8).write(to: url, options: .atomic)
    }

    /// 有请求就删掉并返回 true；一次请求只消费一次。
    @discardableResult
    public static func consumeReset(_ kind: Kind, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(kind.requestFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    public static func hasResetRequest(_ kind: Kind, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(kind.requestFileName).path)
    }

    public static func postResetNotification(_ kind: Kind) {
        DistributedNotificationCenter.default().postNotificationName(
            kind.notification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public static func removeLearningFiles(in directory: URL) {
        for name in ["user.tsv", "history.tsv"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public static func removeStatisticsFile(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(InputStatistics.fileName))
    }
}
