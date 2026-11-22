// 外壳里不按键的测试：数据目录迁移、应用更新（本机假发布页，不碰 GitHub）。

import Foundation
import Carbon

func runAppTests() {
    testConfigMigration()
    testUpdateWithLocalRelease()
    testInputLifecycle()
    testCandidateHitTesting()
    testLearningAndStatisticsClear()
}

/// 设置窗口的清除请求：清内存 + 存空文件；统计文件被删掉。
private func testLearningAndStatisticsClear() {
    let state = AppState.shared
    let fm = FileManager.default
    try? "ni hao\t你好\t1000\n".write(toFile: state.userDictPath, atomically: true, encoding: .utf8)
    try? "w\t你好\t2\t1\np\t你好\t世界\t1\t2\n".write(toFile: state.historyPath, atomically: true, encoding: .utf8)
    state.clearLearning()
    check(LearningData.counts(in: state.supportDir) == LearningData.Counts(), "清除学习：文件和内存都清空")
    check(!LearningData.hasResetRequest(.learning, in: state.supportDir), "清除学习：请求已消费")

    let statistics = state.supportDir.appendingPathComponent(InputStatistics.fileName)
    try? "{}".write(to: statistics, atomically: true, encoding: .utf8)
    state.clearStatistics()
    check(!fm.fileExists(atPath: statistics.path), "清除统计：文件删掉")
    check(!LearningData.hasResetRequest(.statistics, in: state.supportDir), "清除统计：请求已消费")
}

/// 候选框的鼠标命中：`cells` 的第 i 个就是这一页第 i 个候选，空白处不误触。
private func testCandidateHitTesting() {
    let page = CandidatePage(texts: ["你好", "尼好", "你号"], cursor: 1,
                             hasPrev: false, hasNext: true, expanded: false)
    let layout = CandidateLayout(page: page, fontSize: 17)
    check(layout.cells.count == 3, "鼠标：三个候选三个可点区域", "\(layout.cells.count)")
    for (i, cell) in layout.cells.enumerated() {
        let point = NSPoint(x: cell.frame.midX, y: cell.frame.midY)
        check(layout.cellIndex(at: point) == i, "鼠标：第 \(i + 1) 个候选命中", "\(String(describing: layout.cellIndex(at: point)))")
    }
    check(layout.cellIndex(at: NSPoint(x: -100, y: -100)) == nil, "鼠标：候选外面的空白不选")
}

private func testInputLifecycle() {
    let state = AppState.shared
    state.reclaimIdleEngine()
    check(state.engine == nil, "内存：空闲词库可释放")
    let (controller, client) = session(["InputStatistics": "True"])
    type(controller, "nihao")
    check(state.engine == nil && client.markedText.contains("nihao"), "内存：后台冷载入保住首键", client.markedText)
    press(controller, .space)
    state.waitForEngine()
    check(client.committed == "你好", "内存：冷载入期间按的空格在就绪后确认候选", client.committed)
    state.reclaimIdleEngine()
    check(state.engine != nil, "内存：有组词会话时不释放词库")
    controller.deactivateServer(client)
    if !IsSecureEventInputEnabled() {
        let count = InputStatistics.read(in: state.supportDir).recentDays(1).last?.count
        check(count == .init(characters: 2, commits: 1), "统计：输入控制器上屏，失焦时保存日计数")
    }
    state.reclaimIdleEngine()
    check(state.engine == nil, "内存：失焦后可释放词库")
    writeConfig([:])
    state.loadConfig()
    state.waitForEngine()
}

private func testConfigMigration() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mytype-apptests-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let old = dir.appendingPathComponent("wowtype.conf").path
    let new = dir.appendingPathComponent("mytype.conf").path

    // 只有旧的：改名为新的，内容不变
    try? writeText("PageSize=5\n", to: old)
    AppState.migrateLegacyConfig(in: dir)
    check(!fm.fileExists(atPath: old), "迁移设置：旧的 wowtype.conf 不在了")
    check(readText(new) == "PageSize=5\n", "迁移设置：内容原样到 mytype.conf")

    // 两个都在：新的不动，旧的也不删
    try? writeText("PageSize=4\n", to: old)
    try? writeText("PageSize=6\n", to: new)
    AppState.migrateLegacyConfig(in: dir)
    check(readText(new) == "PageSize=6\n", "迁移设置：已有 mytype.conf 时不动它")
    check(fm.fileExists(atPath: old), "迁移设置：旧的留在原地")

    // 只有新的、两个都没有：不做事
    try? fm.removeItem(atPath: old)
    AppState.migrateLegacyConfig(in: dir)
    check(readText(new) == "PageSize=6\n", "迁移设置：只有新的时不动")
    try? fm.removeItem(atPath: new)
    AppState.migrateLegacyConfig(in: dir)
    check(!fm.fileExists(atPath: old) && !fm.fileExists(atPath: new), "迁移设置：都没有时不乱建")
}

/// 本机起一个假发布页：/latest 302 到 /releases/tag/v0.5.2，资产目录里放 pkg 和 SHA256SUMS。
/// 更新器读 MYTYPE_UPDATE_LATEST_URL / MYTYPE_UPDATE_BASE_URL，只走普通 HTTP，不用 GitHub API。
private final class LocalRelease {
    let root: URL
    let process: Process
    let base: String

    init?() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mytype-release-\(UUID().uuidString)")
        let assets = root.appendingPathComponent("releases/download/v0.5.2")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            // 假 pkg 不用真能装，只测下载和 SHA256 校验
            try Data((0..<100_000).map { UInt8($0 % 251) }).write(to: assets.appendingPathComponent("MyType-0.5.2-macos.pkg"))
        } catch {
            return nil
        }
        let script = root.appendingPathComponent("server.py")
        let code = """
        import http.server, os, sys
        root = sys.argv[1]
        class H(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **kw):
                super().__init__(*a, directory=root, **kw)
            def do_GET(self):
                if self.path == "/latest":
                    self.send_response(302)
                    self.send_header("Location", "/releases/tag/v0.5.2")
                    self.end_headers()
                elif self.path == "/latest-none":
                    self.send_response(302)
                    self.send_header("Location", "/releases")
                    self.end_headers()
                else:
                    super().do_GET()
            def log_message(self, *a):
                pass
        s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        open(os.path.join(root, "port.txt"), "w").write(str(s.server_address[1]))
        s.serve_forever()
        """
        guard (try? code.write(to: script, atomically: true, encoding: .utf8)) != nil else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let portFile = root.appendingPathComponent("port.txt")
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: portFile.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let text = readText(portFile.path), let port = Int(text.trimmed) else {
            process.terminate()
            return nil
        }
        self.root = root
        self.process = process
        self.base = "http://127.0.0.1:\(port)"
    }

    deinit {
        process.terminate()
        try? FileManager.default.removeItem(at: root)
    }

    var assets: URL { root.appendingPathComponent("releases/download/v0.5.2") }
}

private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let start = Date()
    while !condition() && Date().timeIntervalSince(start) < timeout {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return condition()
}

private func testUpdateWithLocalRelease() {
    guard let server = LocalRelease() else {
        check(false, "更新：本机假发布页没起来")
        return
    }
    setenv("MYTYPE_UPDATE_LATEST_URL", server.base + "/latest", 1)
    setenv("MYTYPE_UPDATE_BASE_URL", server.base + "/releases/download/v0.5.2", 1)
    defer {
        unsetenv("MYTYPE_UPDATE_LATEST_URL")
        unsetenv("MYTYPE_UPDATE_BASE_URL")
    }

    // 检查：302 到 tag
    var checked: Result<UpdateRelease, Error>?
    Updater.shared.checkLatest { checked = $0 }
    let done = waitUntil(15) { checked != nil }
    check(done, "更新：检查有回调")
    guard case .success(let release)? = checked else {
        check(false, "更新：从 302 读出 tag", "\(String(describing: checked))")
        return
    }
    check(release.tag == "v0.5.2" && release.version == "0.5.2", "更新：解析 tag 和版本")
    check(release.package == "MyType-0.5.2-macos.pkg", "更新：安装包名")

    // 下载并按 SHA256SUMS 校验
    let pkg = server.assets.appendingPathComponent(release.package)
    let digest = (try? FileHash.sha256(of: pkg)) ?? ""
    try? writeText("\(digest)  \(release.package)\n", to: server.assets.appendingPathComponent("SHA256SUMS").path)
    var downloaded: URL?
    var downloadError: Error?
    do { downloaded = try Updater.shared.download(release) { _, _ in } } catch { downloadError = error }
    check(downloaded != nil, "更新：下载安装包", "\(String(describing: downloadError))")
    if let file = downloaded {
        check((try? FileHash.sha256(of: file)) == digest, "更新：下载的文件校验和对")
        try? FileManager.default.removeItem(at: file)
    }

    // 校验和对不上：不返回文件，报校验错
    try? writeText("\(String(repeating: "0", count: 64))  \(release.package)\n",
                   to: server.assets.appendingPathComponent("SHA256SUMS").path)
    do {
        _ = try Updater.shared.download(release) { _, _ in }
        check(false, "更新：校验不对时不该接受")
    } catch {
        check("\(error)".contains("校验和"), "更新：校验不对时报错", "\(error)")
    }

    // 测试进程不在 ~/Library/Input Methods：只给发布页，不真的装
    if let file = downloaded ?? Optional(pkg) {
        do {
            try Updater.shared.install(package: file)
            check(false, "更新：测试进程不该调 installer")
        } catch {
            check("\(error)".contains("系统目录"), "更新：只有用户目录能自动装", "\(error)")
        }
    }

    // 设置窗口「关于」页的数据层：同样的发布页，检查完成后 updateLatest 有值
    let model = SettingsModel(page: .about)
    model.checkUpdates()
    check(waitUntil(15) { model.updateChecked }, "更新：设置窗口的检查有结果")
    check(model.updateLatest?.version == "0.5.2", "更新：设置窗口拿到新版",
          "\(String(describing: model.updateLatest)) / \(model.updateError ?? "")")
    check(model.updateError == nil, "更新：设置窗口没有报错", model.updateError ?? "")

    // 跳到 /releases（没有正式版）：检查失败
    setenv("MYTYPE_UPDATE_LATEST_URL", server.base + "/latest-none", 1)
    var none: Result<UpdateRelease, Error>?
    Updater.shared.checkLatest { none = $0 }
    check(waitUntil(15) { none != nil }, "更新：没有正式版时有回调")
    if case .failure? = none {
        check(true, "更新：没有正式版时报错")
    } else {
        check(false, "更新：没有正式版时不该成功", "\(String(describing: none))")
    }
}
