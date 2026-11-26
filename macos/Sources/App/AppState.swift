// 进程里只有一份的东西：词库（后台载入）、设置、数据目录、定时保存学习数据、互译的翻译器。

import AppKit

final class AppState {
    static let shared = AppState()
    static let lexiconStateChanged = Notification.Name("io.github.yxxbc.MyType.lexiconStateChanged")

    /// 后台载入完成前是 nil；输入控制器每次按键时来取（换词库时换成新的）。
    private(set) var engine: Engine?
    private final class EngineLoad {
        let done = DispatchGroup()
        let path: String
        let stamp: FileStamp?
        let start = Date()
        var result: Engine?

        init(path: String) {
            self.path = path
            stamp = FileStamp(path)
        }
    }
    private var loading: EngineLoad?
    private weak var activeInputClient: MyTypeInputController?
    var isPreparingEngine: Bool { loading != nil && engine == nil }
    private var engineIdleWork: DispatchWorkItem?
    private var inputStatistics: InputStatistics?
    private var statisticsDirty = false
    private var statisticsSaveWork: DispatchWorkItem?
    /// 载入途中设置又换了词库：载完再看一次
    private var reloadAfterLoading = false
    private var commitsSinceSave = 0
    private var learningSaveWork: DispatchWorkItem?
    /// 每上屏这么多次存一次（系统可能随时杀掉输入法进程）。
    private let saveEvery = 20

    /// mytype.conf 的内容。改了以后 configGeneration 加一，输入控制器照着重新设置会话。
    private(set) var config = MyTypeConfig()
    private(set) var configGeneration = 0
    /// 互译的翻译器：设置里第一次打开 Translate 时建，之后一直留着（和以前一样），所有输入框共用。
    /// 本地模型的 llama-server 也只有这一个，第一次翻译时才起
    private(set) var translator: Translator?
    /// 正在用的词库文件，和它载入时的 (大小, 修改时间)
    private var lexiconInUse: String?
    private var lexiconStamp: FileStamp?
    private var configStamp: FileStamp?
    private var customStamp: FileStamp?
    private var lastCheck: TimeInterval = 0
    /// 互译本地模型现在用的 llama-server（空的是没找到）
    private var llamaServerInUse = ""
    /// 上次找 llama-server 的时间（没找到时最多 5 秒找一次，不在按键路径上每秒查文件）
    private var llamaProbe: TimeInterval = 0
    private var missingLexiconLogged: String?
    /// 上一次看系统剪贴板时它的 changeCount（没变就不读）
    private var clipboardChangeCount = -1
    /// 后台监听 supportDir 变更（避免在按键主线程上做文件 stat）
    private var dirMonitor: DispatchSourceFileSystemObject?
    private var dirMonitorFd: Int32 = -1
    private var bgPollTimer: DispatchSourceTimer?

    private init() {
        AppState.migrateLegacyConfig(in: supportDir)
        RecentEmoji.shared.path = supportDir.appendingPathComponent("emoji-recent.txt").path
    }

    /// 0.6.0 起设置文件叫 mytype.conf。旧版留下的 wowtype.conf 还在、新的没有时改过来。
    /// 两个都在（比如刚降级跑过一次）时不动新的，旧文件留在原地。
    static func migrateLegacyConfig(in dir: URL) {
        let fm = FileManager.default
        let old = dir.appendingPathComponent("wowtype.conf").path
        let new = dir.appendingPathComponent("mytype.conf").path
        guard !fm.fileExists(atPath: new), fm.fileExists(atPath: old) else { return }
        try? fm.moveItem(atPath: old, toPath: new)
    }

    // 第一次要画候选框时才建窗口（自检时没有图形界面）
    private var panelCreated = false
    lazy var candidatePanel: CandidatePanel = {
        panelCreated = true
        let panel = CandidatePanel()
        panel.fontSize = CGFloat(config.candidateFontSize)
        return panel
    }()

    /// 安装包里的数据（词库、英文词表、语言模型）。
    var resourceDir: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    }

    /// 用户数据：~/Library/Application Support/MyType（测试时可用 MYTYPE_DATA_DIR 换个地方）
    var supportDir: URL {
        if let dir = ProcessInfo.processInfo.environment["MYTYPE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyType", isDirectory: true)
    }

    var userDictPath: String { supportDir.appendingPathComponent("user.tsv").path }
    var historyPath: String { supportDir.appendingPathComponent("history.tsv").path }
    /// 设置，键名见 ~/Library/Application Support/MyType/mytype.conf
    var configPath: String { supportDir.appendingPathComponent("mytype.conf").path }
    /// 自定义词（常用语），格式见 ~/Library/Application Support/MyType/custom.tsv
    var customWordsPath: String { supportDir.appendingPathComponent("custom.tsv").path }
    /// 互译的 API Key（一行，0600），见 ~/Library/Application Support/MyType/translate.key；不写进 mytype.conf
    var translateKeyPath: String { supportDir.appendingPathComponent("translate.key").path }
    /// 改 mytype.conf 的 Lexicon，只动这一项（命令行 --install-lexicon / --use-lexicon 用）。
    /// 输入法按键时看到文件变了就换词库；万象包更新了、路径没变时，词库文件的大小、时间变了也会重载。
    func setLexicon(_ path: String) throws {
        let text = readText(configPath)
        let base = MyTypeConfig.parse(text ?? "")
        var wanted = base
        wanted.lexicon = path
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try writeText(wanted.merged(changesFrom: base, into: text), to: configPath)
    }

    /// 本地翻译模型，设置里 TranslateLocalModel 留空时用（见 ~/Library/Application Support/MyType/models/）
    /// 语音识别模型（设置窗口「语音」页下载），见 ~/Library/Application Support/MyType/wtlocal
    var voiceModelDir: String { VoiceModelInstaller.folder(in: supportDir).path }

    var localModelPath: String {
        supportDir.appendingPathComponent("models/HY-MT1.5-1.8B-Q4_K_M.gguf").path
    }

    /// 设置里没填 TranslateLlamaServer 时去哪找 llama-server：输入法是系统启动的，PATH 里只有
    /// /usr/bin 这些，Homebrew 装的 llama.cpp 要自己找。都没有时交给核心（PATH、~/Library/Application Support/MyType/llama）。
    func findLlamaServer() -> String {
        let candidates = [supportDir.appendingPathComponent("llama/llama-server").path,
                          "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/opt/local/bin/llama-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    /// 实际用哪个词库：设置里的 Lexicon（文件在才用）> 安装包里的雾凇词库。
    func lexiconPath() -> String? {
        let configured = config.lexicon
        if !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return path
            }
            if missingLexiconLogged != path {
                missingLexiconLogged = path
                NSLog("MyType: 设置里的词库 %@ 不在，用自带的词库", path)
            }
        }
        return bundledLexiconPath()
    }

    /// 安装包里的词库。词库旁边会写一份快照（.wcache，下次启动快很多）；安装包是签过名的，
    /// 不能往里写，所以在数据目录放一个指向安装包里词库的链接，快照就落在数据目录。
    private func bundledLexiconPath() -> String? {
        let bundled = resourceDir.appendingPathComponent("lexicon.tsv")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        let link = supportDir.appendingPathComponent("lexicon.tsv")
        let fm = FileManager.default
        // 第一次启动时数据目录还没有：先建，不然链接建不成，快照就写进安装包了
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != bundled.path {
            try? fm.removeItem(at: link)
            if (try? fm.createSymbolicLink(at: link, withDestinationURL: bundled)) == nil {
                return bundled.path
            }
        }
        return link.path
    }

    func resource(_ name: String) -> String? {
        let path = resourceDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 读设置文件。没有就用默认值（和以前一样，不自动建文件；设置窗口改了设置、或者用文本编辑打开时才建）。
    func loadConfig() {
        configStamp = FileStamp(configPath)
        let loaded = MyTypeConfig.load(path: configPath)
        if loaded != config || configGeneration == 0 {
            config = loaded
            configGeneration += 1
            applyTranslateSettings()
            NSLog("MyType: 设置 %@ 每页%d 模糊音=%d(%u) 纠错=%d 双拼=%d(%@) 五笔=%d Shift切换=%@ 繁体=%d 半角标点=%d 字号=%d 词库=%@ 工具栏=%d 剪贴板历史=%d 表情键=%@ 互译=%@",
                  config.horizontal ? "横排" : "竖排", config.pageSize, config.fuzzy ? 1 : 0, config.fuzzyGroups,
                  config.typoCorrection ? 1 : 0, config.shuangpin ? 1 : 0, config.shuangpinScheme, config.wubi ? 1 : 0,
                  config.shiftToggle.rawValue, config.traditional ? 1 : 0, config.halfwidthPunct ? 1 : 0,
                  config.candidateFontSize, config.lexicon.isEmpty ? "自带" : config.lexicon,
                  config.toolbar ? 1 : 0, config.clipboardHistory ? 1 : 0, config.emojiKey?.name ?? "不用",
                  translateSummary())
        }
        applyPanelSettings()
    }

    /// 设置里管互译的部分。和以前一样，打开过一次就留着翻译器（关掉时只是切不到「译」）；
    /// 不用本地模型了马上停掉 llama-server。
    private func applyTranslateSettings() {
        if config.translate && translator == nil {
            translator = Translator()
        }
        guard let translator else { return }
        // 手动建的 Key 文件权限可能太宽，收紧到只有自己能读
        TranslateKeyFile.tighten(translateKeyPath)
        guard config.translate else {
            // 关掉互译也要停掉本地模型的 llama-server（docs/CONFIG.md 的承诺）：
            // 只停进程，配置和模型文件都留着，重新打开时按需再起。
            translator.releaseLocal()
            llamaServerInUse = ""
            return
        }
        llamaServerInUse = config.translateLocal ? findLlamaServer() : ""
        translator.configure(config, keyFile: translateKeyPath, defaultLocalModel: localModelPath,
                             llamaServer: llamaServerInUse)
    }

    /// 内存压力（main.swift 的内存压力源）：本地翻译模型的 llama-server 占 1.5 GB 左右，
    /// 先停掉。配置和模型文件都留着，下次翻译时按需再起。
    func reclaimLocalTranslation() {
        translator?.releaseLocal()
    }

    private func translateSummary() -> String {
        guard config.translate else { return "关" }
        guard let translator, translator.isReady else { return "开（未配置，切不到「译」）" }
        let service = config.translateLocal ? "本地 HY-MT" : "\(config.translateModel) @ \(config.translateBaseUrl)"
        return "开（\(service) → \(config.translateTarget)）"
    }

    /// 退出时停掉本地模型的 llama-server（它是输入法起的子进程）。
    func shutdownTranslator() {
        translator?.configure(MyTypeConfig(), keyFile: "", defaultLocalModel: "")
    }

    /// 候选框的设置（字号）。
    private func applyPanelSettings() {
        // 候选框是第一次要画时才建的，自检时不要建窗口
        guard panelCreated else { return }
        candidatePanel.fontSize = CGFloat(config.candidateFontSize)
    }

    /// 设置里管引擎的部分 + 自定义词。
    private func applyEngineSettings(_ engine: Engine) {
        for problem in engine.apply(config, conversion: resource("s2t.tsv"), wubi: resource("wubi86.tsv")) {
            NSLog("MyType: %@", problem)
        }
        customStamp = FileStamp(customWordsPath)
        let custom = engine.loadCustomWords(customWordsPath)
        if custom < 0 {
            NSLog("MyType: 自定义词载入失败 %@", customWordsPath)
        } else if custom > 0 {
            NSLog("MyType: 载入自定义词 %d 条", custom)
        }
    }

    /// 同步载入（自检和后台线程用）。只读文件，设置在主线程上由 install 套上。
    func makeEngine(lexicon: String, loadLearning: Bool = true) -> Engine? {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let engine = Engine(lexicon: lexicon, languageModel: resource("words.lm"))
            ?? Engine(lexicon: lexicon)
        else {
            NSLog("MyType: 载入词库失败 %@", lexicon)
            return nil
        }
        if let english = resource("english.txt") {
            engine.loadEnglish(english)
        }
        // 用户自己训的领域词级模型（可选），和 words.lm 混着用
        let domain = supportDir.appendingPathComponent("words.domain.lm").path
        if FileManager.default.fileExists(atPath: domain) {
            if engine.setDomainLM(domain) {
                NSLog("MyType: 载入领域词级模型 %@", domain)
            } else {
                NSLog("MyType: 领域词级模型载入失败 %@", domain)
            }
        }
        if loadLearning { readLearning(into: engine) }
        return engine
    }

    private func readLearning(into engine: Engine) {
        engine.loadUserDict(userDictPath)
        engine.loadHistory(historyPath)
    }

    /// 自检用：读设置、载入词库、套上设置。
    func makeConfiguredEngine() -> Engine? {
        loadConfig()
        guard let lexicon = lexiconPath() else {
            NSLog("MyType: 安装包里没有 lexicon.tsv")
            return nil
        }
        guard let engine = makeEngine(lexicon: lexicon) else { return nil }
        applyEngineSettings(engine)
        return engine
    }

    func activateInputClient(_ client: MyTypeInputController) {
        activeInputClient = client
        engineIdleWork?.cancel()
        engineIdleWork = nil
        // 设置窗口在输入法没跑的时候点了「清除学习数据/统计」：请求文件还在，先处理
        clearLearningIfRequested()
        clearStatisticsIfRequested()
        startBackgroundWatcher()
        if engine == nil && loading == nil { loadEngineInBackground() }
    }

    func deactivateInputClient(_ client: MyTypeInputController) {
        guard activeInputClient === client else { return }
        activeInputClient = nil
        stopBackgroundWatcher()
        scheduleEngineReclaim()
    }

    private func startBackgroundWatcher() {
        if dirMonitor == nil {
            let fd = open(supportDir.path, O_EVTONLY)
            if fd >= 0 {
                dirMonitorFd = fd
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete],
                    queue: DispatchQueue.global(qos: .utility)
                )
                source.setEventHandler { [weak self] in
                    DispatchQueue.main.async {
                        self?.checkForChanges(force: true)
                    }
                }
                source.setCancelHandler { [weak self] in
                    if let fd = self?.dirMonitorFd, fd >= 0 {
                        close(fd)
                        self?.dirMonitorFd = -1
                    }
                }
                source.resume()
                dirMonitor = source
            }
        }
        if bgPollTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let hasLlama = !self.findLlamaServer().isEmpty
                DispatchQueue.main.async {
                    // 在主线程安全比对 stamp / llamaProbe，完全不阻塞按键路径
                    if hasLlama && self.translator != nil && self.llamaServerInUse.isEmpty {
                        self.checkForChanges(force: true)
                    } else if let wanted = self.lexiconPath(),
                              wanted != self.lexiconInUse || FileStamp(wanted) != self.lexiconStamp {
                        self.checkForChanges(force: true)
                    }
                }
            }
            timer.resume()
            bgPollTimer = timer
        }
    }

    private func stopBackgroundWatcher() {
        dirMonitor?.cancel()
        dirMonitor = nil
        bgPollTimer?.cancel()
        bgPollTimer = nil
    }

    private func scheduleEngineReclaim() {
        engineIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reclaimIdleEngine() }
        engineIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func reclaimIdleEngine() {
        guard activeInputClient == nil, loading == nil else { return }
        engineIdleWork?.cancel()
        engineIdleWork = nil
        // 写失败先保留引擎，下次再试，不能把未落盘的用户词扔掉。
        guard saveLearning() else { scheduleEngineReclaim(); return }
        engine = nil
        lexiconInUse = nil
        lexiconStamp = nil
    }

    /// 隔离测试的同步入口。输入法自身只走后台载入。
    func waitForEngine() {
        guard engine == nil else { return }
        if loading == nil { loadEngineInBackground() }
        guard let job = loading else { return }
        job.done.wait()
        finishEngineLoad(job, waitForLearning: true)
    }

    private func loadEngineInBackground() {
        if configGeneration == 0 {
            loadConfig()
        }
        guard loading == nil else { return }
        guard let lexicon = lexiconPath() else {
            NSLog("MyType: 安装包里没有 lexicon.tsv")
            return
        }
        let job = EngineLoad(path: lexicon)
        loading = job
        DistributedNotificationCenter.default().postNotificationName(
            AppState.lexiconStateChanged, object: "loading", userInfo: nil, deliverImmediately: true)
        job.done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            job.result = self.makeEngine(lexicon: lexicon, loadLearning: false)
            job.done.leave()
            DispatchQueue.main.async {
                self.finishEngineLoad(job)
            }
        }
    }

    /// 底库载好了以后换上它。
    ///
    /// `waitForLearning` 只有隔离测试用（要同步返回）：输入法自己永远把读学习数据放到后台，
    /// 因为 user.tsv 可能几千行、history.tsv 上万行，读在按键的主线程上会卡住首键。
    /// 顺序不能变：先 `saveLearning()` 把旧引擎学到的落盘，再读进新引擎，否则会丢掉
    /// 后台载入期间新学的词。读的这段时间 `loading` 还占着，别的路径不会同时再载入。
    private func finishEngineLoad(_ job: EngineLoad, waitForLearning: Bool = false) {
        guard loading === job else { return }
        NSLog("MyType: 词库 %@ 载入%@，用时 %.1f 秒", job.path, job.result == nil ? "失败" : "完成",
              Date().timeIntervalSince(job.start))
        guard let prepared = job.result, saveLearning() else {
            loading = nil
            if job.result == nil {
                DistributedNotificationCenter.default().postNotificationName(
                    AppState.lexiconStateChanged, object: "failed", userInfo: nil, deliverImmediately: true)
            }
            afterEngineLoad()
            return
        }
        if waitForLearning {
            readLearning(into: prepared)
            installEngine(prepared, job)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // 只碰新引擎和用户数据文件，不和旧引擎并发
                self?.readLearning(into: prepared)
                DispatchQueue.main.async { self?.installEngine(prepared, job) }
            }
        }
    }

    private func installEngine(_ prepared: Engine, _ job: EngineLoad) {
        guard loading === job else { return }
        loading = nil
        applyEngineSettings(prepared)
        engine = prepared
        lexiconInUse = job.path
        lexiconStamp = job.stamp
        DistributedNotificationCenter.default().postNotificationName(
            AppState.lexiconStateChanged, object: "ready", userInfo: nil, deliverImmediately: true)
        afterEngineLoad()
    }

    private func afterEngineLoad() {
        if reloadAfterLoading {
            reloadAfterLoading = false
            checkForChanges(force: true)
        }
        if !isPreparingEngine { activeInputClient?.enginePreparationFinished() }
        if activeInputClient == nil && engine != nil { scheduleEngineReclaim() }
    }

    /// 用本地模型互译、之前没找到 llama-server 时，最多 5 秒看一次现在有没有了。
    private func llamaServerAppeared(now: TimeInterval) -> Bool {
        guard config.translate, config.translateLocal, llamaServerInUse.isEmpty, now - llamaProbe >= 5 else {
            return false
        }
        llamaProbe = now
        return !findLlamaServer().isEmpty
    }

    /// 看看设置、自定义词、词库文件改了没有（按键时调，一秒最多看一次；切换输入框时 force）。
    /// 设置改了马上生效；换了词库在后台载入，载完之前照旧用旧的。
    func checkForChanges(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheck >= 1 else { return }
        lastCheck = now
        // 设置窗口的清除请求（它也会发通知；收不到时下一次按键兜底）
        clearLearningIfRequested()
        clearStatisticsIfRequested()
        if translator != nil && (force || llamaServerAppeared(now: now)) {
            // 切换输入框时再配一次（顺带收紧 Key 文件的权限）；本地模型的 llama-server 之前没找到、现在有了
            // （设置窗口里刚下好，或者后来才 brew install 的）也重配，不用切输入框。
            // 模型文件不用这样盯：核心判断「就绪」时每次都现看模型在不在
            applyTranslateSettings()
        }
        if FileStamp(configPath) != configStamp {
            let generation = configGeneration
            loadConfig()
            if configGeneration != generation, let engine {
                for problem in engine.apply(config, conversion: resource("s2t.tsv"), wubi: resource("wubi86.tsv")) {
                    NSLog("MyType: %@", problem)
                }
            }
        }
        if let engine, FileStamp(customWordsPath) != customStamp {
            customStamp = FileStamp(customWordsPath)
            let custom = engine.loadCustomWords(customWordsPath)
            NSLog("MyType: 自定义词改了，重新载入 %d 条", custom)
        }
        guard engine != nil || loading != nil else { return }
        let wanted = lexiconPath()
        if let wanted, wanted != lexiconInUse || FileStamp(wanted) != lexiconStamp {
            if loading != nil {
                reloadAfterLoading = true
            } else if engine != nil {
                NSLog("MyType: 换词库 %@ -> %@", lexiconInUse ?? "", wanted)
                loadEngineInBackground()
            }
        }
    }

    /// 设置窗口「文件」菜单「用文本编辑打开设置文件」：没有设置文件就写一份全是默认值的，用文本编辑打开。
    func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? MyTypeConfig.template().write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        openInTextEditor(configPath)
    }

    /// 设置窗口「文件」菜单「用文本编辑打开自定义词」：custom.tsv，格式见 docs/CONFIG.md。
    func openCustomWordsFile() {
        if !FileManager.default.fileExists(atPath: customWordsPath) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let header = """
            # 自定义词（常用语）：一行一个，编码<TAB>词[<TAB>频次]。加进去的词总排在候选第一个，简拼也能打。
            # 编码一般是拼音（可以用空格分音节），也可以是别的字母（mail）；词里 \\n 是换行。
            # 例：
            # zi jie tiao dong	字节跳动
            # mail	hello@example.com

            """
            try? header.write(toFile: customWordsPath, atomically: true, encoding: .utf8)
        }
        openInTextEditor(customWordsPath)
    }

    private func openInTextEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 剪贴板历史（设置里 ClipboardHistory 打开时）：看一眼系统剪贴板，有新的文字就交给核心记（只在内存里）。
    /// 切换输入框、打开工具栏的剪贴板页时调；changeCount 没变就不读。
    /// 密码管理器复制的密码会标上 nspasteboard.org 的 ConcealedType（还有 TransientType、AutoGeneratedType），不记。
    func sampleClipboard() {
        guard config.clipboardHistory else {
            // 关着时核心已经清空了；再打开时把那时剪贴板上的记下来
            clipboardChangeCount = -1
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount
        let skipped: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                    "org.nspasteboard.AutoGeneratedType"]
        guard let types = pasteboard.types, !types.contains(where: { skipped.contains($0.rawValue) }),
              let text = pasteboard.string(forType: .string)
        else {
            return
        }
        ClipboardHistory.remember(text)
    }

    /// 上屏里有学到的选词（Composer.onCommit 只在 frame->learned 时调）。
    func didCommit() {
        commitsSinceSave += 1
        if commitsSinceSave >= saveEvery {
            _ = saveLearning()
        } else if learningSaveWork == nil {
            let work = DispatchWorkItem { [weak self] in _ = self?.saveLearning() }
            learningSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    /// Ctrl+Delete 忘掉了学错的词：马上存（不等攒够上屏次数）。
    func didForget() {
        commitsSinceSave += 1
        _ = saveLearning()
    }

    func recordInputStatistics(_ text: String) {
        clearStatisticsIfRequested()
        guard config.inputStatistics else { return }
        let characters = InputStatistics.countHan(in: text)
        guard characters > 0 else { return }
        if inputStatistics == nil { inputStatistics = InputStatistics.read(in: supportDir) }
        inputStatistics?.record(characters: characters)
        statisticsDirty = true
        if statisticsSaveWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.saveStatistics() }
            statisticsSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func saveStatistics() {
        statisticsSaveWork?.cancel()
        statisticsSaveWork = nil
        clearStatisticsIfRequested()
        guard statisticsDirty, let inputStatistics else { return }
        do {
            try inputStatistics.write(in: supportDir)
            statisticsDirty = false
        } catch {
            NSLog("MyType: 保存输入统计失败")
        }
    }

    func save() {
        // 退出前先处理设置里刚点的清除请求，别让旧数据又被写回去
        clearLearningIfRequested()
        clearStatisticsIfRequested()
        saveStatistics()
        _ = saveLearning()
    }

    /// 设置里「清除学习数据」：清掉内存里的用户词、热度和搭配，再存一份空的。
    /// 自定义词和基础词库不动。请求文件由设置窗口写，这里消费。
    func clearLearning() {
        LearningData.consumeReset(.learning, in: supportDir)
        engine?.clearLearning()
        commitsSinceSave = 0
        learningSaveWork?.cancel()
        learningSaveWork = nil
        if engine != nil {
            _ = saveLearning(force: true)
        } else {
            // 输入法没跑（或者还没载入词库）：直接删文件，下次启动就是空的
            LearningData.removeLearningFiles(in: supportDir)
        }
    }

    private func clearLearningIfRequested() {
        guard LearningData.hasResetRequest(.learning, in: supportDir) else { return }
        clearLearning()
    }

    /// 设置里「清除输入统计」：清掉内存里的日计数和待存数据，再删掉文件。
    func clearStatistics() {
        LearningData.consumeReset(.statistics, in: supportDir)
        statisticsSaveWork?.cancel()
        statisticsSaveWork = nil
        statisticsDirty = false
        inputStatistics = InputStatistics()
        LearningData.removeStatisticsFile(in: supportDir)
    }

    private func clearStatisticsIfRequested() {
        guard LearningData.hasResetRequest(.statistics, in: supportDir) else { return }
        clearStatistics()
    }

    @discardableResult
    private func saveLearning(force: Bool = false) -> Bool {
        learningSaveWork?.cancel()
        learningSaveWork = nil
        // 设置里刚点了清除：先把内存清掉再存，别把旧数据写回去。force 是 clearLearning 自己
        // 调的，不能再走一遍，否则递归。
        if !force {
            clearLearningIfRequested()
        }
        guard let engine, force || commitsSinceSave > 0 else { return true }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let dictSaved = engine.saveUserDict(userDictPath)
        if !dictSaved {
            NSLog("MyType: 保存用户词库失败")
        }
        let historySaved = engine.saveHistory(historyPath)
        if !historySaved {
            NSLog("MyType: 保存输入习惯失败")
        }
        // 两样都存上了才清零：存失败的那批下次接着存（和以前一样）
        if dictSaved && historySaved {
            commitsSinceSave = 0
        }
        return dictSaved && historySaved
    }
}

/// 文件的 (大小, 修改时间)；文件不在是 nil。用来看文件改了没有。
struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date

    init?(_ path: String) {
        // 自带词库是指向安装包的链接：看链接指向的文件
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              let modified = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        self.modified = modified
    }
}
