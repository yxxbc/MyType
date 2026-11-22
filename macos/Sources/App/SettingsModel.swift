// 设置窗口的数据：mytype.conf 和 custom.tsv。
//
// 设置窗口只写文件：输入法按键时（AppState.checkForChanges）看到文件变了自己重新读，下一次按键就生效。
// 改设置停 0.25 秒才写（拖数字时不要每一下都写），只写窗口里改过的键（MyTypeConfig.merged），
// 窗口开着时在文本编辑里改的、别的键不会被盖掉；切回窗口时文件变了就重新读。

import AppKit
import AVFoundation
import CMyType

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, input, statistics, learning, emoji, voice, translate, words, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .input: return "输入"
        case .statistics: return "输入统计"
        case .learning: return "学习"
        case .emoji: return "表情"
        case .voice: return "语音"
        case .translate: return "翻译"
        case .words: return "自定义词"
        case .about: return "关于"
        }
    }

    /// SF Symbols（macOS 11 起都有）
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .input: return "keyboard"
        case .statistics: return "chart.bar.xaxis"
        case .learning: return "lightbulb"
        case .emoji: return "face.smiling"
        case .voice: return "mic"
        case .translate: return "character.bubble"
        case .words: return "book.closed"
        case .about: return "info.circle"
        }
    }
}

struct SettingsToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage
    @Published var config: MyTypeConfig {
        didSet {
            if config != oldValue && !quiet {
                scheduleSave()
            }
        }
    }
    @Published private(set) var words: [CustomWords.Entry] = []
    @Published private(set) var toast: SettingsToast?
    @Published private(set) var inputDays: [InputStatistics.Day] = []
    @Published private(set) var learningCounts = LearningData.Counts()

    // 「添加自定义词」的两个框：打词时自动填拼音，手改过编码就不再自动填（清空了又自动填）
    @Published var newWord = "" {
        didSet {
            if newWord != oldValue { wordChanged() }
        }
    }
    @Published var newCode = "" {
        didSet {
            if !quiet && newCode != oldValue { codeEdited = !newCode.trimmed.isEmpty }
        }
    }
    @Published var search = ""

    let configPath: String
    let customPath: String
    let supportDir: URL
    /// 互译的 API Key 文件（0600），不写进 mytype.conf
    let translateKeyPath: String
    /// TranslateLocalModel 留空时用的模型位置
    let defaultLocalModel: String
    /// 互译的 API Key 有没有设置（不读出来显示）
    @Published private(set) var translateKeySet = false
    /// 万象词库：装好的版本（没装 nil）、最新发布页（查过才有）、正在下载 / 安装时的进度
    @Published private(set) var wanxiangVersion: String?
    @Published private(set) var release: LexiconPackInstaller.Release?
    @Published private(set) var releaseError: String?
    @Published private(set) var lexiconProgress: String?
    var lexiconBusy: Bool { lexiconProgress != nil }
    private var releaseChecking = false
    /// 应用更新：发布页上的新版（没有就是 nil）、检查/下载/安装的状态
    @Published private(set) var updateLatest: UpdateRelease?
    @Published private(set) var updateError: String?
    @Published private(set) var updateChecking = false
    @Published private(set) var updateChecked = false
    @Published private(set) var updateProgress: String?
    @Published private(set) var updateInstalling = false
    private var updateCheckedOnce = false
    /// 安装包里的雾凇词库（猜拼音用；设置里换了词库就用换的那个）
    private let bundledLexicon: String?
    /// 安装包里有五笔码表（wubi86.tsv）：没有时「五笔输入」灰掉，说为什么
    let wubiTableAvailable: Bool

    /// 文件里现在的设置（上次读或写的）：保存时只写 config 和它不一样的键
    private var saved: MyTypeConfig
    private var configStamp: FileStamp?
    private var customStamp: FileStamp?
    private var quiet = false
    private var codeEdited = false
    private var saveWork: DispatchWorkItem?
    private var guessWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private let guesser = PinyinGuesser()

    init(page: SettingsPage, state: AppState = .shared) {
        self.page = page
        configPath = state.configPath
        customPath = state.customWordsPath
        supportDir = state.supportDir
        translateKeyPath = state.translateKeyPath
        defaultLocalModel = state.localModelPath
        translateKeySet = !TranslateKeyFile.read(state.translateKeyPath).isEmpty
        wanxiangVersion = LexiconPack.installedVersion(folder: LexiconPackInstaller.folder(in: state.supportDir).path)
        let knownUpdate = UpdateState.available(current: appVersion)
        updateLatest = knownUpdate
        updateChecked = knownUpdate != nil
        bundledLexicon = state.resource("lexicon.tsv")
        wubiTableAvailable = state.resource("wubi86.tsv") != nil
        configStamp = FileStamp(state.configPath)
        let loaded = MyTypeConfig.parse(readText(state.configPath) ?? "")
        saved = loaded
        config = loaded
        customStamp = FileStamp(state.customWordsPath)
        words = CustomWords(text: readText(state.customWordsPath)).entries
        learningCounts = LearningData.counts(in: supportDir)
    }

    private func quietly(_ body: () -> Void) {
        let was = quiet
        quiet = true
        body()
        quiet = was
    }

    // MARK: 设置

    /// 切回窗口时：文件在别处改了（文本编辑、同步）就重新读。窗口里还没写的先写（只写改过的键，不会盖掉别处的）。
    func reload() {
        save()
        if page == .statistics { refreshInputStatistics() }
        if page == .learning { refreshLearning() }
        // Key 也可能在输入法菜单的「设置互译 API Key…」里改过
        translateKeySet = !TranslateKeyFile.read(translateKeyPath).isEmpty
        if FileStamp(configPath) != configStamp {
            configStamp = FileStamp(configPath)
            let loaded = MyTypeConfig.parse(readText(configPath) ?? "")
            saved = loaded
            quietly { config = loaded }
        }
        if FileStamp(customPath) != customStamp {
            customStamp = FileStamp(customPath)
            words = CustomWords(text: readText(customPath)).entries
        }
    }

    func refreshInputStatistics(days: Int = 14) {
        inputDays = InputStatistics.read(in: supportDir).recentDays(days)
    }

    func refreshLearning() {
        learningCounts = LearningData.counts(in: supportDir)
    }

    /// 清除自动学到的数据：写请求文件（输入法下一个键或通知时清内存），删掉现有文件，
    /// 这样设置窗口立刻显示 0；输入法在跑的话会把空表再存回来。自定义词不动。
    func clearLearningData() {
        LearningData.requestReset(.learning, in: supportDir)
        LearningData.removeLearningFiles(in: supportDir)
        LearningData.postResetNotification(.learning)
        refreshLearning()
        showToast("学习数据已清除")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshLearning() }
    }

    /// 清掉本机保存的每日输入统计。和清除学习数据一样用请求文件通知输入法。
    func clearInputStatistics() {
        LearningData.requestReset(.statistics, in: supportDir)
        LearningData.removeStatisticsFile(in: supportDir)
        LearningData.postResetNotification(.statistics)
        refreshInputStatistics(days: max(inputDays.count, 14))
        showToast("输入统计已清除")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshInputStatistics(days: max(self?.inputDays.count ?? 14, 14))
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 写互译的 API Key（空串删掉）。Key 不进 mytype.conf，输入法下一次翻译时读。
    func setTranslateKey(_ key: String) {
        if TranslateKeyFile.write(key, to: translateKeyPath) {
            translateKeySet = !TranslateKeyFile.read(translateKeyPath).isEmpty
            showToast(translateKeySet ? "API Key 已保存" : "API Key 已删除")
        } else {
            showToast("API Key 没写进去：\(translateKeyPath)")
        }
    }

    /// 本地翻译模型现在用的文件和它在不在。
    var localModelFile: (path: String, exists: Bool) {
        let path = config.translateLocalModel.isEmpty
            ? defaultLocalModel : (config.translateLocalModel as NSString).expandingTildeInPath
        return (path, FileManager.default.fileExists(atPath: path))
    }

    /// 马上写（关窗口、退出、用文本编辑打开之前）。
    func save() {
        saveWork?.cancel()
        saveWork = nil
        guard config != saved else { return }
        let out = config.merged(changesFrom: saved, into: readText(configPath))
        do {
            try writeText(out, to: configPath)
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return
        }
        configStamp = FileStamp(configPath)
        let now = MyTypeConfig.parse(out)
        saved = now
        if now != config {
            quietly { config = now }
        }
    }

    /// 恢复默认设置：词库不动（和以前一样），自定义词不受影响。
    func resetToDefaults() {
        var defaults = MyTypeConfig()
        defaults.lexicon = config.lexicon
        config = defaults
        save()
        showToast("已恢复默认设置")
    }

    /// 词库：设置里的文件在就用它，不然用安装包里的（和输入法的 AppState.lexiconPath 一样）。
    var customLexiconMissing: Bool {
        !config.lexicon.isEmpty && !isFile(expand(config.lexicon))
    }

    private var lexiconForGuess: String? {
        if !config.lexicon.isEmpty, isFile(expand(config.lexicon)) {
            return expand(config.lexicon)
        }
        return bundledLexicon
    }

    // MARK: 应用更新（检查发布页、下载 pkg、交给 installer）

    /// 打开「关于」页时自动查一次；手动点「检查更新」也走这里。
    func checkUpdates(manual: Bool = false) {
        guard !updateChecking, !updateInstalling else { return }
        updateChecking = true
        updateError = nil
        Updater.shared.checkLatest { [weak self] result in
            guard let self else { return }
            self.updateChecking = false
            self.updateChecked = true
            switch result {
            case .success(let release):
                self.updateLatest = Update.isNewer(release.version, than: appVersion) ? release : nil
                UpdateState.note(release, current: appVersion)
                if manual {
                    self.showToast(self.updateLatest == nil ? "已经是最新版（MyType \(appVersion)）"
                                                            : "有新版本 MyType \(release.version)")
                }
            case .failure(let error):
                self.updateError = "检查更新失败：\(error.localizedDescription)"
                if manual { self.showToast(self.updateError ?? "检查更新失败") }
            }
        }
    }

    func checkUpdatesOnce() {
        guard !updateCheckedOnce else { return }
        updateCheckedOnce = true
        checkUpdates()
    }

    /// 确认后下载、校验，再交给系统的 installer。安装时 MyType 会退出，装完 postinstall 重新打开。
    func updateNow() {
        guard let release = updateLatest, !updateInstalling else { return }
        let alert = NSAlert()
        alert.messageText = "更新到 MyType \(release.version)？"
        alert.informativeText = "要下载 \(release.package)。\n安装时 MyType 会退出，装好后自动重新打开并切回来；"
            + "设置、用户词和自定义词都会保留。"
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        updateInstalling = true
        updateProgress = "正在连接…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> URL in
                try Updater.shared.download(release) { done, total in
                    let text = total > 0
                        ? "正在下载：\(LocalModel.sizeText(done)) / \(LocalModel.sizeText(total))（\(done * 100 / total)%）"
                        : "正在下载：\(LocalModel.sizeText(done))"
                    DispatchQueue.main.async { self?.updateProgress = text }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let package):
                    self.updateProgress = "正在安装，MyType 会退出并自动重开…"
                    self.save()  // 安装器会停掉进程，先把设置写下去
                    do {
                        try Updater.shared.install(package: package)
                    } catch {
                        self.updateInstalling = false
                        self.updateProgress = nil
                        self.updateError = "没装上：\(error.localizedDescription)"
                        self.showToast(self.updateError ?? "没装上")
                    }
                case .failure(let error):
                    self.updateInstalling = false
                    self.updateProgress = nil
                    self.updateError = "更新没下完：\(error.localizedDescription)"
                    self.showToast(self.updateError ?? "更新没下完")
                }
            }
        }
    }

    /// 打开发布页（自动更新用不了时的退路，或者想看这次更新内容）。
    func openReleasePage() {
        let url = updateLatest.map { Update.releasePage(tag: $0.tag) } ?? Update.latestPage
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    }

    // MARK: 万象词库（和设置窗口的「万象拼音」一样）

    enum LexiconKind { case rimeIce, wanxiang, custom }

    var wanxiangLexicon: String { LexiconPackInstaller.lexicon(in: supportDir) }

    var lexiconKind: LexiconKind {
        if config.lexicon.isEmpty { return .rimeIce }
        return expand(config.lexicon) == wanxiangLexicon ? .wanxiang : .custom
    }

    /// 发布页上有比装着的更新的万象包
    var wanxiangUpdate: String? {
        guard let installed = wanxiangVersion, let latest = release?.wanxiang?.version,
              LexiconPack.compareVersions(latest, installed) > 0 else { return nil }
        return latest
    }

    /// 打开「输入」页时看一眼发布页（有没有万象包、有没有新版）；只看一次
    func checkRelease() {
        guard release == nil, !releaseChecking else { return }
        releaseChecking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try LexiconPackInstaller.fetchLatest() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.releaseChecking = false
                switch result {
                case .success(let release): self.release = release
                case .failure(let error): self.releaseError = "\(error.localizedDescription)"
                }
            }
        }
    }

    func useRimeIce() {
        config.lexicon = ""
        showToast("已切回雾凇拼音，几秒后生效")
    }

    /// 选万象：装了就切过去，没装先下载
    func useWanxiang() {
        if wanxiangVersion == nil {
            installWanxiang()
        } else {
            config.lexicon = wanxiangLexicon
            showToast("已切到万象拼音，几秒后生效")
        }
    }

    /// 下载（或从 file）装万象，装好切过去。
    func installWanxiang(from file: URL? = nil) {
        guard !lexiconBusy else { return }
        lexiconProgress = file == nil ? "正在连接…" : "正在安装…"
        let supportDir = self.supportDir
        let known = release
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (String, LexiconPackInstaller.Release?) in
                guard let file else {
                    let latest = try known ?? LexiconPackInstaller.fetchLatest()
                    let tarball = try LexiconPackInstaller.download(latest) { done, total in
                        let text = total > 0
                            ? "正在下载：\(LocalModel.sizeText(done)) / \(LocalModel.sizeText(total))（\(done * 100 / total)%）"
                            : "正在下载：\(LocalModel.sizeText(done))"
                        DispatchQueue.main.async { [weak self] in self?.lexiconProgress = text }
                    }
                    defer { try? FileManager.default.removeItem(at: tarball) }
                    DispatchQueue.main.async { [weak self] in self?.lexiconProgress = "正在安装…" }
                    return (try LexiconPackInstaller.install(tarball, supportDir: supportDir), latest)
                }
                return (try LexiconPackInstaller.install(file, supportDir: supportDir), nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lexiconProgress = nil
                self.wanxiangVersion = LexiconPack.installedVersion(folder: LexiconPackInstaller.folder(in: supportDir).path)
                switch result {
                case .success(let (version, latest)):
                    if let latest { self.release = latest }
                    self.config.lexicon = self.wanxiangLexicon
                    self.save() // 路径没变（更新了词库包）也写一次；输入法看到词库文件变了就重载
                    self.showToast("已装好万象拼音 \(version)，几秒后生效")
                case .failure(let error):
                    self.showToast("万象拼音没装好：\(error)")
                }
            }
        }
    }

    func chooseWanxiangFile() {
        let panel = NSOpenPanel()
        panel.title = "安装万象词库包"
        panel.message = "选 wowtype-data-wanxiang-<版本>.tar.gz"
        panel.prompt = "安装"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            self.installWanxiang(from: url)
        }
    }

    /// 删掉万象（正在用时不让删，和以前一样）
    func removeWanxiang() {
        guard lexiconKind != .wanxiang, !lexiconBusy else { return }
        let freed = LexiconPackInstaller.remove(supportDir: supportDir)
        wanxiangVersion = nil
        showToast("已删除万象拼音，空出 \(LocalModel.sizeText(freed))")
    }

    func chooseLexicon() {
        let panel = NSOpenPanel()
        panel.title = "选择自定义词库"
        panel.message = "每行：拼音<TAB>词<TAB>频次，拼音用空格分开音节"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !config.lexicon.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expand(config.lexicon)).deletingLastPathComponent()
        }
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            self.config.lexicon = (url.path as NSString).abbreviatingWithTildeInPath
            self.showToast("已切到自定义词库，几秒后生效")
        }
    }

    // MARK: 本地翻译模型（和设置窗口的「离线翻译模型」一样：缺什么下什么）

    /// 正在下载时的进度（nil：没在下载）
    // MARK: 语音模型（和设置窗口的「语音」页一样：从腾讯的 CDN 下载官方离线语音包）

    /// 下载中的进度（已下, 总共）；没在下是 nil
    @Published private(set) var voiceProgress: (Int64, Int64)?
    @Published private(set) var voiceError: String?
    @Published private var voiceRevision = 0
    /// 麦克风测试：正在录、上次结果；权限变化时用 revision 让界面刷新
    @Published private(set) var voiceTesting = false
    @Published private(set) var voiceTestText: String?
    @Published private(set) var voicePermissionRevision = 0
    private var voiceControl: DownloadControl?
    var voiceBusy: Bool { voiceProgress != nil }

    var voiceModelReady: Bool {
        _ = voiceRevision
        return VoiceModelInstaller.isReady(supportDir: supportDir)
    }

    /// 「语音模型」那一行的状态，和以前一样
    var voiceModelStatus: String {
        _ = voiceRevision
        if let (done, total) = voiceProgress {
            if done == 0 { return "正在连接…" }
            if total > 0 && done >= total { return "正在解包…" }
            return total > 0
                ? "正在下载：\(LocalModel.sizeText(done)) / \(LocalModel.sizeText(total))（\(done * 100 / total)%）"
                : "正在下载：\(LocalModel.sizeText(done))"
        }
        if voiceModelReady {
            return "已下载（\(LocalModel.sizeText(LexiconPackInstaller.folderSize(VoiceModelInstaller.folder(in: supportDir)))))"
        }
        if let voiceError { return "没下载好：\(voiceError)" }
        let part = VoiceModelInstaller.pack(in: supportDir).path + ".part"
        if FileManager.default.fileExists(atPath: part) {
            return "下了 \(LocalModel.sizeText(LocalModelInstaller.fileSize(part))) / "
                + "\(LocalModel.sizeText(VoiceModelInstaller.size))，可以接着下"
        }
        return "要下载 \(LocalModel.sizeText(VoiceModelInstaller.size))，解开后约 130 MB"
    }

    /// 麦克风权限的文字（第一次、已允许、被拒绝）
    var voicePermissionText: String {
        _ = voicePermissionRevision
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "已允许"
        case .denied: return "被拒绝：系统设置 → 隐私与安全性 → 麦克风，打开 MyType"
        case .restricted: return "被系统限制"
        case .notDetermined: return "还没问过（点「测试」会问）"
        @unknown default: return "未知"
        }
    }

    /// 用麦克风录 3 秒，走和输入法一样的核心识别，把结果写在「上次测试」里。
    func testMicrophone() {
        guard !voiceTesting, voiceModelReady else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.voicePermissionRevision += 1
                    self.showToast(granted ? "麦克风已允许，再点一次「测试」"
                                           : "麦克风被拒绝：系统设置 → 隐私与安全性 → 麦克风，打开 MyType")
                }
            }
            return
        default:
            showToast("麦克风被拒绝：系统设置 → 隐私与安全性 → 麦克风，打开 MyType")
            return
        }
        voiceTesting = true
        voiceTestText = "正在听 3 秒…"
        let folder = VoiceModelInstaller.folder(in: supportDir).path
        let duckPlayback = config.voiceDuckPlayback
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var text = ""
            var failure: String?
            if let voice = mytype_voice_new(folder) {
                if #available(macOS 14.0, *) { mytype_voice_set_duck_playback(voice, duckPlayback ? 1 : 0) }
                mytype_voice_key_down(voice)
                Thread.sleep(forTimeInterval: 3)
                mytype_voice_key_up(voice)
                let start = Date()
                while Date().timeIntervalSince(start) < 30 {
                    let phase = Int(mytype_voice_poll(voice))
                    text = mytype_voice_text(voice).map { String(cString: $0) } ?? ""
                    if phase == Int(MYTYPE_VOICE_RESULT) { break }
                    if phase == Int(MYTYPE_VOICE_ERROR) {
                        failure = text
                        break
                    }
                    usleep(50_000)
                }
                mytype_voice_free(voice)
            } else {
                failure = "核心没带语音"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.voiceTesting = false
                if let failure {
                    self.voiceTestText = "出错：\(failure)"
                    self.showToast("麦克风测试：\(failure)")
                } else if text.isEmpty {
                    self.voiceTestText = "没听清"
                    self.showToast("麦克风测试：没听清")
                } else {
                    self.voiceTestText = text
                    self.showToast("麦克风没问题：\(text)")
                }
            }
        }
    }

    /// 让正在跑的输入法进程退出，下次按键时由系统重新拉起：重新读语音模型和麦克风权限。
    private func reloadInputMethod() {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleIdentifier ?? Installer.bundleID
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        where app.processIdentifier != me && app.activationPolicy == .accessory {
            app.terminate()
        }
    }

    func downloadVoiceModel() {
        guard !voiceBusy else { return }
        let control = DownloadControl()
        voiceControl = control
        voiceError = nil
        voiceProgress = (0, VoiceModelInstaller.size)
        let supportDir = self.supportDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try VoiceModelInstaller.install(supportDir: supportDir, control: control) { done, total in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.voiceControl === control else { return }
                        self.voiceProgress = (done, total)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.voiceControl = nil
                self.voiceProgress = nil
                self.voiceRevision += 1
                switch result {
                case .success:
                    self.config.voice = true
                    // 顺手问一下麦克风权限，免得第一次按语音键时才弹框（同一个程序，输入法那边也认）；
                    // 允许后把输入法进程重启，让它重新读模型和权限
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            self.voicePermissionRevision += 1
                            if granted {
                                self.save()  // 先写文件，再让输入法重启，不然它读到的是旧的 Voice=False
                                self.reloadInputMethod()
                                self.showToast("语音模型和麦克风都好了，回到输入框按住\(self.voiceKeyLabel) 说话")
                            } else {
                                self.showToast("麦克风被拒绝了：系统设置 → 隐私与安全性 → 麦克风，打开 MyType")
                            }
                        }
                    }
                case .failure(let error as DownloadCancelled):
                    self.showToast(error.description)
                case .failure(let error as PackError):
                    self.voiceError = error.description
                case .failure(let error):
                    self.voiceError = error.localizedDescription
                }
            }
        }
    }

    func cancelVoiceDownload() {
        voiceControl?.cancel()
    }

    func removeVoiceModel() {
        guard !voiceBusy else { return }
        let freed = VoiceModelInstaller.remove(supportDir: supportDir)
        config.voice = false
        voiceRevision += 1
        showToast(freed > 0 ? "已删除语音模型，空出 \(LocalModel.sizeText(freed))，语音输入已关闭" : "已删除")
    }

    /// 语音键在界面上的叫法
    var voiceKeyLabel: String {
        VoiceKey.presets.first { $0.name == config.voiceKey }?.label ?? config.voiceKey
    }

    @Published private(set) var localProgress: LocalModelInstaller.Progress?
    /// 上次没下完的原因，再点下载时清掉
    @Published private(set) var localError: String?
    /// 下载完、删除后加一，让界面重新看文件
    @Published private var localRevision = 0
    private var localControl: DownloadControl?

    var localBusy: Bool { localProgress != nil }

    /// 还差什么：模型看 localModelFile，llama-server 和输入法找的地方一样
    var localPlan: LocalModel.Plan {
        LocalModelInstaller.plan(model: localModelFile.path, customServer: config.translateLlamaServer,
                                 supportDir: supportDir)
    }

    /// 翻译配好了：本地模型下载好了，或者填了翻译服务的地址和模型
    var translateConfigured: Bool {
        config.translateLocal ? localPlan.ready : !config.translateBaseUrl.isEmpty && !config.translateModel.isEmpty
    }

    /// 「译」进得去：互译打开了，翻译也配好了
    var translateReady: Bool { config.translate && translateConfigured }

    /// 输入法会用的 llama-server，和它是哪来的
    var localServerSummary: String? {
        guard let server = LocalModelInstaller.findServer(custom: config.translateLlamaServer, supportDir: supportDir)
        else { return nil }
        if server == LocalModelInstaller.downloadedServer(in: supportDir) {
            return "MyType 下载的 llama.cpp \(LocalModelInstaller.downloadedBuild(in: supportDir) ?? "")"
        }
        return (server as NSString).abbreviatingWithTildeInPath
    }

    /// 有没有能删的：下载的模型（自己写了位置的不算）、下了一半的、下载的 llama-server
    var localDeletable: Bool {
        let fm = FileManager.default
        let model = config.translateLocalModel.isEmpty ? defaultLocalModel : nil
        return model.map { fm.fileExists(atPath: $0) || fm.fileExists(atPath: $0 + ".part") } == true
            || fm.fileExists(atPath: LocalModelInstaller.llamaDir(in: supportDir).path)
    }

    /// 点「下载」：要下模型时先确认许可（下了一半接着下、只差 llama-server 时不再问）
    func downloadLocalModel() {
        let plan = localPlan
        guard !localBusy, plan.canDownload else { return }
        let model = localModelFile.path
        guard plan.wantModel, !LocalModelInstaller.hasPartial(model: model) else {
            startLocalDownload()
            return
        }
        let alert = NSAlert()
        alert.messageText = "下载离线翻译模型？"
        let llama = plan.wantLlama ? "同时下载运行模型的程序 llama-server（llama.cpp 官方发布，MIT 许可）。" : ""
        alert.informativeText = "一共 \(LocalModel.sizeText(plan.bytes))，下载完会校验文件。\(llama)\n\n"
            + LocalModel.terms + "\n\n点「同意并下载」表示你接受这份许可。"
        alert.accessoryView = LinkButton(title: "许可协议全文", url: URL(string: LocalModel.license)!)
        alert.addButton(withTitle: "同意并下载")
        alert.addButton(withTitle: "取消")
        let answered: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.startLocalDownload()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    private func startLocalDownload() {
        let plan = localPlan
        guard !localBusy, plan.canDownload else { return }
        let control = DownloadControl()
        localControl = control
        localError = nil
        localProgress = LocalModelInstaller.Progress(stage: .connecting, done: 0, total: plan.bytes)
        let model = localModelFile.path
        let supportDir = self.supportDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try LocalModelInstaller.install(plan, model: model, supportDir: supportDir, control: control) { progress in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.localControl === control else { return }
                        self.localProgress = progress
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localControl = nil
                self.localProgress = nil
                self.localRevision += 1
                switch result {
                case .success:
                    // 输入法切换输入框时会重新找 llama-server、看模型在不在
                    self.showToast(self.localPlan.ready ? "下载好了，可以用离线翻译了" : "模型下载好了")
                case .failure(let error as DownloadCancelled):
                    self.showToast(error.description)
                case .failure(let error as PackError):
                    self.localError = error.description
                case .failure(let error):
                    self.localError = error.localizedDescription
                }
            }
        }
    }

    func cancelLocalDownload() {
        localControl?.cancel()
    }

    /// 删掉下载的模型和下载的 llama-server（Homebrew 装的、自己写了位置的模型不动）
    func removeLocalModel() {
        guard !localBusy else { return }
        let model = config.translateLocalModel.isEmpty ? defaultLocalModel : nil
        let freed = LocalModelInstaller.remove(model: model, supportDir: supportDir)
        localError = nil
        localRevision += 1
        showToast(freed > 0 ? "已删除，空出 \(LocalModel.sizeText(freed))" : "已删除")
    }

    /// 确认框里的「许可协议全文」链接
    private final class LinkButton: NSButton {
        private var url: URL?

        convenience init(title: String, url: URL) {
            self.init(frame: .zero)
            self.url = url
            isBordered = false
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
            target = self
            action = #selector(open)
            sizeToFit()
        }

        @objc private func open() {
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: 自定义词

    var codeIsInvalid: Bool {
        !newCode.trimmed.isEmpty && CustomWords.normalizeCode(newCode) == nil
    }

    var canAddWord: Bool {
        CustomWords.isValidWord(newWord.trimmed) && CustomWords.normalizeCode(newCode) != nil
    }

    /// 「已添加」列表：后加的在前面，按词或编码搜（编码不管空格），最多列 500 个。
    var shownWords: [CustomWords.Entry] {
        let query = search.trimmed.lowercased()
        let compact = query.replacingOccurrences(of: " ", with: "")
        return Array(words.reversed().filter { entry in
            query.isEmpty || entry.word.lowercased().contains(query)
                || entry.code.replacingOccurrences(of: " ", with: "").contains(compact)
        }.prefix(500))
    }

    private func wordChanged() {
        guessWork?.cancel()
        guard !codeEdited else { return }
        let word = newWord.trimmed
        if word.isEmpty {
            quietly { newCode = "" }
            return
        }
        // 查词库要几十毫秒，打字停一下再查
        let lexicon = lexiconForGuess
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let guess = self.guesser.guess(word, lexicon: lexicon)
                DispatchQueue.main.async {
                    guard !self.codeEdited, self.newWord.trimmed == word else { return }
                    self.quietly { self.newCode = guess ?? "" }
                }
            }
        }
        guessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 加词。成功返回 true（两个框清空）。
    @discardableResult
    func addWord() -> Bool {
        let word = newWord.trimmed
        if !codeEdited && newCode.trimmed.isEmpty && !word.isEmpty {
            // 还没来得及猜：现在猜
            guessWork?.cancel()
            quietly { newCode = guesser.guess(word, lexicon: lexiconForGuess) ?? "" }
        }
        guard CustomWords.isValidWord(word) else {
            if word.contains("\t") || word.contains("\n") {
                showToast("词里不能有 TAB 和换行，换行写成 \\n")
            }
            return false
        }
        guard let code = CustomWords.normalizeCode(newCode) else {
            showToast("编码不对：拼音用空格隔开音节（zhang san），或者只用字母（mail）")
            return false
        }
        var doc = readCustomWords()
        let replaced = doc.add(code: code, word: word)
        guard writeCustomWords(doc) else { return false }
        quietly {
            newWord = ""
            newCode = ""
        }
        codeEdited = false
        showToast(replaced ? "已更新「\(CustomWords.shown(word))」" : "已添加「\(CustomWords.shown(word))」，打 \(code.replacingOccurrences(of: " ", with: "")) 试试")
        return true
    }

    func removeWord(_ word: String) {
        var doc = readCustomWords()
        let removed = doc.remove(word: word)
        guard !removed.isEmpty, writeCustomWords(doc) else { return }
        showToast("已删除「\(CustomWords.shown(word))」", actionTitle: "撤销") { [weak self] in
            guard let self else { return }
            var doc = self.readCustomWords()
            for entry in removed {
                doc.add(code: entry.code, word: entry.word)
            }
            self.writeCustomWords(doc)
        }
    }

    func importWords() {
        let panel = NSOpenPanel()
        panel.title = "导入自定义词"
        panel.message = "每行：编码<TAB>词（MyType 导出的文件、以前的 custom.tsv 都行）"
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                self.showToast("读不了这个文件（要 UTF-8 文本）")
                return
            }
            let incoming = CustomWords.parseImport(text)
            guard !incoming.isEmpty else {
                self.showToast("文件里没有能用的词（每行：编码<TAB>词）")
                return
            }
            var doc = self.readCustomWords()
            let (added, updated) = doc.merge(incoming)
            guard self.writeCustomWords(doc) else { return }
            self.showToast("导入了 \(added) 个新词" + (updated > 0 ? "，更新 \(updated) 个" : ""))
        }
    }

    func exportWords() {
        let panel = NSSavePanel()
        panel.title = "导出自定义词"
        panel.nameFieldStringValue = "mytype-custom-words.tsv"
        panel.prompt = "导出"
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            let doc = self.readCustomWords()
            do {
                try doc.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showToast("导出失败：\(error.localizedDescription)")
                return
            }
            self.showToast("已导出 \(doc.entries.count) 个词到 \((url.path as NSString).abbreviatingWithTildeInPath)")
        }
    }

    /// 每次改之前重新读文件（窗口开着时文本编辑里改的不丢），改完马上写。
    private func readCustomWords() -> CustomWords {
        CustomWords(text: readText(customPath))
    }

    @discardableResult
    private func writeCustomWords(_ doc: CustomWords) -> Bool {
        do {
            try writeText(doc.text, to: customPath)
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return false
        }
        customStamp = FileStamp(customPath)
        words = doc.entries
        return true
    }

    // MARK: 提示条

    func showToast(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toastWork?.cancel()
        toast = SettingsToast(text: text, actionTitle: actionTitle, action: action)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 3 : 6), execute: work)
    }

    func runToastAction() {
        let action = toast?.action
        toastWork?.cancel()
        toast = nil
        action?()
    }

    // MARK: 文件

    /// 打开、存文件的对话框：有窗口就挂在窗口上。
    private func present(_ panel: NSSavePanel, _ done: @escaping (URL?) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

/// 读文本文件；不在是 nil。不是 UTF-8 也读出来（坏的字节换成 �），免得当成没有文件、整个重写。
/// 12.3 MB 这样的写法
func readText(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// 整个换掉（先写临时文件再改名）。文件是个链接（比如链到同步盘）时写链接指向的文件。
func writeText(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

private func isFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
}

/// 从词库猜拼音：词库文件映射进内存（不占内存，几十毫秒查一次），换了词库换文件。
final class PinyinGuesser {
    private let lock = NSLock()
    private var path: String?
    private var data: Data?

    func guess(_ word: String, lexicon: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let lexicon, !word.isEmpty else { return nil }
        if path != lexicon {
            path = lexicon
            data = try? Data(contentsOf: URL(fileURLWithPath: lexicon), options: .alwaysMapped)
        }
        return data?.withUnsafeBytes { CustomWords.guessPinyin(word, lexicon: $0) }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
