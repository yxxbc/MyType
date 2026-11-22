import Foundation

func checkLearningData() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mytype-learning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    check(LearningData.counts(in: dir) == LearningData.Counts(), "学习数据：没有文件时是 0")
    try? "# 注释\nni hao\t你好\t1000\n".write(to: dir.appendingPathComponent("user.tsv"), atomically: true, encoding: .utf8)
    try? "# 注释\nw\t你好\t2\t1\nw\t世界\t1\t2\np\t你好\t世界\t1\t2\n".write(
        to: dir.appendingPathComponent("history.tsv"), atomically: true, encoding: .utf8)
    let counts = LearningData.counts(in: dir)
    check(counts.userWords == 1 && counts.historyWords == 2 && counts.pairs == 1,
          "学习数据：数用户词、选词和搭配", "\(counts)")

    LearningData.requestReset(.learning, in: dir)
    check(LearningData.hasResetRequest(.learning, in: dir), "学习数据：写出清除请求")
    check(LearningData.consumeReset(.learning, in: dir), "学习数据：消费清除请求")
    check(!LearningData.hasResetRequest(.learning, in: dir), "学习数据：请求只消费一次")
    LearningData.removeLearningFiles(in: dir)
    check(LearningData.counts(in: dir) == LearningData.Counts(), "学习数据：删掉学习文件后归零")

    // 统计请求是另一个标记，互不影响
    LearningData.requestReset(.statistics, in: dir)
    check(LearningData.hasResetRequest(.statistics, in: dir), "学习数据：统计也有清除请求")
    check(!LearningData.hasResetRequest(.learning, in: dir), "学习数据：两个请求不串")
    LearningData.consumeReset(.statistics, in: dir)
}
